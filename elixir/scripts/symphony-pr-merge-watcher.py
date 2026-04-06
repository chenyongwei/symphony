#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


API_URL = "https://api.linear.app/graphql"
WATCH_STATES = ("Code Review", "Merging")
DONE_STATE = "Done"
GITHUB_PR_RE = re.compile(r"https://github\.com/([^/]+/[^/]+)/pull/(\d+)(?:/[^\s)?>:]*)?")
LINEAR_MAX_ATTEMPTS = 3


@dataclass(frozen=True)
class WorkflowConfig:
    workflow_path: Path
    project_slug: str
    assignee: str | None


def log(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)


def env_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default)).expanduser()


def discover_workflows(code_root: Path) -> list[Path]:
    workflows: list[Path] = []
    excluded_dir_names = {"archive", "node_modules", ".git"}

    for root, dirs, files in os.walk(code_root):
        dirs[:] = [name for name in dirs if name not in excluded_dir_names]
        if Path(root).name != ".symphony":
            continue
        for filename in files:
            if filename.startswith("WORKFLOW") and filename.endswith(".md"):
                workflows.append(Path(root, filename))

    workflows.sort()
    return workflows


def front_matter_lines(path: Path) -> list[str]:
    try:
        content = path.read_text()
    except FileNotFoundError:
        return []
    lines = content.splitlines()
    if not lines or lines[0].strip() != "---":
        return []

    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return lines[1:index]

    return []


def parse_workflow(path: Path) -> WorkflowConfig | None:
    section: str | None = None
    values: dict[str, str] = {}

    for raw_line in front_matter_lines(path):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        if indent == 0 and stripped.endswith(":"):
            section = stripped[:-1]
            continue

        if indent == 2 and ":" in stripped and section in {"tracker", "workspace"}:
            key, value = stripped.split(":", 1)
            value = value.strip().strip('"').strip("'")
            values[f"{section}.{key.strip()}"] = value

    project_slug = values.get("tracker.project_slug")
    if not project_slug:
        return None

    assignee = values.get("tracker.assignee")
    return WorkflowConfig(workflow_path=path, project_slug=project_slug, assignee=assignee or None)


def linear_graphql(token: str, query: str, variables: dict | None = None) -> dict:
    payload = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
    last_error: Exception | None = None

    for attempt in range(1, LINEAR_MAX_ATTEMPTS + 1):
        request = urllib.request.Request(
            API_URL,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": token,
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = json.loads(response.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            if 500 <= exc.code < 600 and attempt < LINEAR_MAX_ATTEMPTS:
                time.sleep(attempt)
                last_error = RuntimeError(f"Linear API HTTP {exc.code}: {error_body}")
                continue
            raise RuntimeError(f"Linear API HTTP {exc.code}: {error_body}") from exc
        except urllib.error.URLError as exc:
            if attempt < LINEAR_MAX_ATTEMPTS:
                time.sleep(attempt)
                last_error = RuntimeError(f"Linear API request failed: {exc}")
                continue
            raise RuntimeError(f"Linear API request failed: {exc}") from exc
    else:
        assert last_error is not None
        raise last_error

    if body.get("errors"):
        raise RuntimeError(f"Linear GraphQL errors: {body['errors']}")

    return body


def viewer_id(token: str) -> str:
    query = """
    query SymphonyMergeWatcherViewer {
      viewer {
        id
      }
    }
    """
    data = linear_graphql(token, query)
    viewer = data.get("data", {}).get("viewer", {})
    value = viewer.get("id")
    if not isinstance(value, str) or not value:
        raise RuntimeError("Unable to resolve Linear viewer id")
    return value


def fetch_project_issues_in_states(token: str, project_slug: str, state_names: tuple[str, ...]) -> list[dict]:
    query = """
    query SymphonyMergeWatcherIssues($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $after: String) {
      issues(
        filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}
        first: $first
        after: $after
      ) {
        nodes {
          id
          identifier
          title
          description
          state {
            name
          }
          assignee {
            id
          }
          attachments {
            nodes {
              title
              url
              sourceType
            }
          }
          comments(last: 100) {
            nodes {
              body
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """

    issues: list[dict] = []
    after: str | None = None

    while True:
        data = linear_graphql(
            token,
            query,
            {
                "projectSlug": project_slug,
                "stateNames": list(state_names),
                "first": 50,
                "after": after,
            },
        )
        payload = data.get("data", {}).get("issues", {})
        issues.extend(payload.get("nodes", []))
        page_info = payload.get("pageInfo", {})
        if not page_info.get("hasNextPage"):
            return issues
        after = page_info.get("endCursor")


def resolve_state_id(token: str, issue_id: str, state_name: str) -> str:
    query = """
    query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
      issue(id: $issueId) {
        team {
          states(filter: {name: {eq: $stateName}}, first: 1) {
            nodes {
              id
            }
          }
        }
      }
    }
    """
    data = linear_graphql(token, query, {"issueId": issue_id, "stateName": state_name})
    nodes = data.get("data", {}).get("issue", {}).get("team", {}).get("states", {}).get("nodes", [])
    if not nodes or not isinstance(nodes[0].get("id"), str):
        raise RuntimeError(f"Unable to resolve Linear state id for {state_name}")
    return nodes[0]["id"]


def update_issue_state(token: str, issue_id: str, state_name: str) -> None:
    mutation = """
    mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        success
      }
    }
    """
    state_id = resolve_state_id(token, issue_id, state_name)
    data = linear_graphql(token, mutation, {"issueId": issue_id, "stateId": state_id})
    success = data.get("data", {}).get("issueUpdate", {}).get("success")
    if success is not True:
        raise RuntimeError(f"Linear issueUpdate failed for {issue_id} -> {state_name}")


def parse_github_pull(url: str) -> tuple[str, str] | None:
    match = GITHUB_PR_RE.match(url)
    if not match:
        return None
    return match.group(1), match.group(2)


def extract_pull_requests_from_text(text: str | None) -> list[tuple[str, str, str]]:
    if not isinstance(text, str):
        return []

    pulls: list[tuple[str, str, str]] = []
    for match in GITHUB_PR_RE.finditer(text):
        url = match.group(0)
        parsed = parse_github_pull(url)
        if not parsed:
            continue
        repo, pr_number = parsed
        pulls.append((repo, pr_number, url))
    return pulls


def attached_pull_requests(issue: dict) -> list[tuple[str, str, str]]:
    seen: set[tuple[str, str]] = set()
    attachments = issue.get("attachments", {}).get("nodes", [])
    pulls: list[tuple[str, str, str]] = []
    for attachment in attachments:
        url = attachment.get("url")
        if not isinstance(url, str):
            continue
        parsed = parse_github_pull(url)
        if not parsed:
            continue
        repo, pr_number = parsed
        key = (repo, pr_number)
        if key in seen:
            continue
        seen.add(key)
        pulls.append((repo, pr_number, url))

    for comment in issue.get("comments", {}).get("nodes", []):
        for repo, pr_number, url in extract_pull_requests_from_text(comment.get("body")):
            key = (repo, pr_number)
            if key in seen:
                continue
            seen.add(key)
            pulls.append((repo, pr_number, url))

    for repo, pr_number, url in extract_pull_requests_from_text(issue.get("description")):
        key = (repo, pr_number)
        if key in seen:
            continue
        seen.add(key)
        pulls.append((repo, pr_number, url))

    return pulls


def fetch_pull_state(repo: str, pr_number: str) -> dict:
    command = [
        "gh",
        "pr",
        "view",
        pr_number,
        "--repo",
        repo,
        "--json",
        "state,mergedAt,url",
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"gh pr view failed for {repo}#{pr_number}")
    return json.loads(result.stdout)


def is_pull_merged(repo: str, pr_number: str) -> bool:
    payload = fetch_pull_state(repo, pr_number)
    return bool(payload.get("mergedAt")) or payload.get("state") == "MERGED"


def cleanup_issue_workspace(symphony_elixir_dir: Path, workflow_path: Path, identifier: str) -> None:
    code = (
        "workflow = Enum.at(System.argv(), 0)\n"
        "identifier = Enum.at(System.argv(), 1)\n"
        "SymphonyElixir.Workflow.set_workflow_file_path(Path.expand(workflow))\n"
        "SymphonyElixir.Workspace.remove_issue_workspaces(identifier)\n"
    )
    command = [
        "mise",
        "exec",
        "--",
        "mix",
        "run",
        "-e",
        code,
        str(workflow_path),
        identifier,
    ]
    result = subprocess.run(command, cwd=symphony_elixir_dir, capture_output=True, text=True)
    if result.returncode != 0:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        raise RuntimeError(stderr or stdout or f"workspace cleanup failed for {identifier}")


def filter_assigned_issues(issues: list[dict], assignee: str | None, current_viewer_id: str | None) -> list[dict]:
    if assignee == "me" and current_viewer_id:
        return [
            issue
            for issue in issues
            if issue.get("assignee", {}).get("id") == current_viewer_id
        ]
    return issues


def scan_once(token: str, symphony_elixir_dir: Path, code_root: Path, current_viewer_id: str | None) -> int:
    actions = 0

    for workflow_path in discover_workflows(code_root):
        if not workflow_path.exists():
            log(f"merge watcher: skipped missing workflow file {workflow_path}")
            continue

        config = parse_workflow(workflow_path)
        if config is None:
            continue

        try:
            issues = fetch_project_issues_in_states(token, config.project_slug, WATCH_STATES)
        except Exception as exc:  # noqa: BLE001
            state_list = ", ".join(WATCH_STATES)
            log(f"merge watcher: failed to fetch review issues ({state_list}) for {config.project_slug}: {exc}")
            continue

        issues = filter_assigned_issues(issues, config.assignee, current_viewer_id)

        for issue in issues:
            pulls = attached_pull_requests(issue)
            if not pulls:
                continue

            issue_id = issue.get("id")
            identifier = issue.get("identifier")
            if not isinstance(issue_id, str) or not isinstance(identifier, str):
                continue

            for repo, pr_number, pr_url in pulls:
                try:
                    merged = is_pull_merged(repo, pr_number)
                except Exception as exc:  # noqa: BLE001
                    log(f"merge watcher: failed to inspect {repo}#{pr_number} for {identifier}: {exc}")
                    continue

                if not merged:
                    continue

                try:
                    update_issue_state(token, issue_id, DONE_STATE)
                    cleanup_issue_workspace(symphony_elixir_dir, workflow_path, identifier)
                    log(f"merge watcher: marked {identifier} Done after merged PR {pr_url} and cleaned workspace")
                    actions += 1
                except Exception as exc:  # noqa: BLE001
                    log(f"merge watcher: failed to finalize {identifier} after merged PR {pr_url}: {exc}")
                break

    return actions


def main() -> int:
    symphony_elixir_dir = env_path("SYMPHONY_ELIXIR_DIR", "~/Code/symphony/elixir")
    code_root = env_path("CODE_ROOT", "~/Code")
    scan_interval = int(os.environ.get("SYMPHONY_MERGE_SCAN_INTERVAL", "30"))
    run_once = "--once" in sys.argv[1:]
    token = os.environ.get("LINEAR_API_KEY")

    if not token:
        log("merge watcher: LINEAR_API_KEY is not set")
        return 1

    if not shutil.which("gh"):
        log("merge watcher: gh is not available in PATH")
        return 1

    viewer = None
    try:
        viewer = viewer_id(token)
    except Exception as exc:  # noqa: BLE001
        log(f"merge watcher: failed to resolve Linear viewer id: {exc}")
        return 1

    if run_once:
        scan_once(token, symphony_elixir_dir, code_root, viewer)
        return 0

    log("merge watcher is running")
    while True:
        scan_once(token, symphony_elixir_dir, code_root, viewer)
        time.sleep(scan_interval)


if __name__ == "__main__":
    raise SystemExit(main())
