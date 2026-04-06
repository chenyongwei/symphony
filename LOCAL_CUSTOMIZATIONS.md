# Local Customizations

This file documents the local, project-specific customizations made on top of the upstream `openai/symphony` checkout in this machine.

The goal of these changes is to make Symphony work as a local multi-project coding orchestrator for the following repos:

- `mf`
- `nest-core`
- `pack-ifc`
- `digital-base`

The upstream file [README.md](/Users/alex/Code/symphony/README.md) remains the source of truth for the base project. This document only covers local customization.

## 1. Repo-owned workflow files

Custom workflows are no longer stored centrally under `symphony/elixir/WORKFLOW.*.md`.

They now live inside each target repo so they can be versioned with the codebase and reused on other machines:

- [mf/.symphony/WORKFLOW.md](/Users/alex/Code/mf/.symphony/WORKFLOW.md)
- [nest-core/.symphony/WORKFLOW.md](/Users/alex/Code/nest-core/.symphony/WORKFLOW.md)
- [pack-ifc/.symphony/WORKFLOW.md](/Users/alex/Code/pack-ifc/.symphony/WORKFLOW.md)
- [digital-base/.symphony/WORKFLOW.md](/Users/alex/Code/mf-platform-repos/digital-base/.symphony/WORKFLOW.md)

This means each repo now owns:

- its Linear project binding
- its repo/workspace copy strategy
- its coding rules
- its PR and review policy

## 2. Linear project bindings

Each workflow is bound to one Linear project and uses `assignee: "me"` so this machine only pulls tickets assigned to the current Linear token owner.

Current bindings:

- `mf` -> `mf-460acadb25e6`
- `nest-core` -> `nest-core-c6a58305eb9c`
- `pack-ifc` -> `pack-ifc-4784fba9af3f`
- `digital-base` -> `digital-base-e80bcca0da75`

## 3. Codex runtime customization

All project workflows explicitly run the local Codex app server with:

- model: `gpt-5.4`
- reasoning: mapped from Linear priority
- `Urgent` -> `xhigh`
- `High` -> `high`
- `Medium` -> `medium`
- `Low` -> `low`
- unset priority -> `high`
- service tier: `fast`

This is enforced in each workflow `codex.command` instead of relying only on global defaults.

Symphony startup was also hardened so source changes under the Symphony Elixir app automatically trigger a fresh `mix build` before launching repo-local instances or autostart-managed services. This prevents stale `bin/symphony` escripts from serving old orchestration behavior after local code changes.

## 4. Human plan-review gate

The workflows were changed so the agent does not start implementation immediately after writing a plan.

Current behavior:

1. Symphony picks up the Linear issue.
2. Symphony core runs a serialized pre-run sync of the checked-out integration branch in the issue workspace before the first Codex turn when the workspace is still on `dev`/`main`/`master`.
3. If the issue is in `Todo`, Symphony immediately advances it to the next configured active state. On this machine that next state is `Plan Progress`.
4. Codex writes the plan into the Linear workpad.
5. The issue moves to `Plan Review` and pauses.
6. A human reviews or edits the plan.
7. A human approves the plan by moving the issue to `Code Progress`.
8. Codex resumes implementation.

This gate is implemented through the `Plan Review Gate` section in each custom workflow.

`Plan Review` is now intentionally non-active, so paused plan-review tickets do not keep waking
agents or burning tokens. Moving the issue to `Code Progress` is the approval signal.

## 5. Git and PR policy

The custom workflows enforce a GitHub-review-based flow instead of direct pushes to integration branches.

Rules added:

- never commit directly to `main`, `master`, or `dev`
- create or reuse `feature/{{ issue.identifier }}`
- push the feature branch
- open a GitHub PR
- write the PR back to Linear immediately after it exists
- do not enter `Code Review` without an open PR attached on the Linear issue
- for app-touching work, run a final E2E walkthrough, capture step-by-step screenshots for each changed user operation, and upload that evidence to Linear before handoff
- for algorithmic work identified by the canonical mapping (`排样`, `排序`, `packing`, `benchmark`, `layout`/`nesting` optimization, routing/packing-result comparison), attach `前后算法结果对比数据` + `前后算法对比e2e截图证据` before handoff
- when embedding screenshots in Linear comments, do not use raw private `uploads.linear.app` asset URLs as Markdown image sources; use a Linear-renderable form instead
- prefer multiple clearer Linear comments over one heavily compressed blurry screenshot dump
- wait for human review and human merge

The review semantics were also clarified:

- `Plan Progress` means planning is actively underway
- `Code Progress` means implementation is actively underway
- `Plan Review` means plan review
- `Code Review` means final code review

## 6. Merge-finalization watcher

The `Code Review` state is no longer handled by long-lived Codex polling turns.

Instead, a lightweight local script now monitors merged GitHub PRs and finalizes the Linear issue
without spending model tokens:

- [symphony-pr-merge-watcher.py](/Users/alex/Code/symphony/elixir/scripts/symphony-pr-merge-watcher.py)

Current behavior:

1. A human moves the issue into `Code Review` after the PR is ready.
2. The PR stays attached to the Linear issue.
3. The local watcher checks GitHub for merged PRs while the issue stays in `Code Review`.
4. After merge, it moves the issue to `Done`.
5. It then cleans the matching Symphony issue workspace.

This means `Code Review` no longer needs an active Codex agent and should not materially consume
model tokens while waiting for the human merge.

## 7. Project-specific workspace behavior

### `mf`

The `mf` workflow treats the repo as a root workspace with multiple child Git repos. It determines the owning repo before branching, committing, pushing, or opening a PR.

### `nest-core`

The `nest-core` workflow treats the repo as a single Rust repo and prefers local build/test entrypoints such as:

- `./scripts/build.sh`
- `cargo build`
- `cargo test`
- `feature/*` pull requests targeting `dev`

Unlike the other two repos, `nest-core` now runs its spawned Codex sessions with:

- `thread_sandbox: danger-full-access`
- `turn_sandbox_policy.type: dangerFullAccess`

This repo-specific exception was added because `workspace-write` blocked `.git` writes needed for `git fetch`, feature branch creation, and PR-oriented Git operations inside the Symphony workspace.

### `pack-ifc`

The `pack-ifc` workflow now treats the repo root as the single owning Git repo and knows that the root also contains large local resource directories used for validation.

## 8. `pack-ifc` repo-root migration

Originally, the real Git repo lived under:

- `/Users/alex/Code/pack-ifc/steel_ifc_stage1`

It was migrated so the repo root is now:

- `/Users/alex/Code/pack-ifc`

This was done so `pack-ifc` can behave like the other repos for:

- workflow placement
- Git operations
- cross-machine deployment
- local Symphony startup

Additional local resource directories at the repo root were added to [pack-ifc/.gitignore](/Users/alex/Code/pack-ifc/.gitignore) to avoid noisy status output.

## 9. Project-local startup commands

Each project now has its own local startup script that defaults to the repo-owned workflow:

- [mf/scripts/start-symphony.sh](/Users/alex/Code/mf/scripts/start-symphony.sh)
- [nest-core/scripts/start-symphony.sh](/Users/alex/Code/nest-core/scripts/start-symphony.sh)
- [pack-ifc/scripts/start-symphony.sh](/Users/alex/Code/pack-ifc/scripts/start-symphony.sh)
- [digital-base/scripts/start-symphony.sh](/Users/alex/Code/mf-platform-repos/digital-base/scripts/start-symphony.sh)

Current default UI ports:

- `mf` -> `4000`
- `nest-core` -> `4001`
- `pack-ifc` -> `4002`
- `digital-base` -> `4003`

Convenience npm entrypoints were also added:

- [mf/package.json](/Users/alex/Code/mf/package.json)
- [nest-core/package.json](/Users/alex/Code/nest-core/package.json)
- [pack-ifc/package.json](/Users/alex/Code/pack-ifc/package.json)
- [digital-base/package.json](/Users/alex/Code/mf-platform-repos/digital-base/package.json)

Usage:

```bash
cd /Users/alex/Code/<repo>
npm run symphony:start
```

## 10. Login-time autostart

A local macOS LaunchAgent was added so Symphony instances start automatically after login.

Key files:

- [symphony-autostart-supervisor.zsh](/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh)
- [symphony-autostart-instance.zsh](/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-instance.zsh)
- [symphony-pr-merge-watcher.py](/Users/alex/Code/symphony/elixir/scripts/symphony-pr-merge-watcher.py)
- [install-symphony-autostart.zsh](/Users/alex/Code/symphony/elixir/scripts/install-symphony-autostart.zsh)
- [uninstall-symphony-autostart.zsh](/Users/alex/Code/symphony/elixir/scripts/uninstall-symphony-autostart.zsh)
- [com.alex.symphony.autostart.plist](/Users/alex/Library/LaunchAgents/com.alex.symphony.autostart.plist)

The supervisor now scans repo-local workflow files under `~/Code`:

- pattern: `*/.symphony/WORKFLOW*.md`

It excludes temporary or irrelevant directories such as:

- `*-symphony-workspaces`
- `archive`
- `node_modules`
- `.git`

The supervisor also ensures the merge watcher stays running alongside the web/UI Symphony instances.

## 11. Stable port mapping

The autostart supervisor maintains a stable workflow-to-port mapping in:

- [workflow_ports.tsv](/Users/alex/Library/Application%20Support/Symphony/workflow_ports.tsv)

Ports start at `4000` and are preserved for already-known workflows when possible, so adding a new workflow does not usually reshuffle existing ports.

## 12. Logs and runtime inspection

Useful runtime locations:

- LaunchAgent logs: [~/Library/Logs/Symphony](/Users/alex/Library/Logs/Symphony)
- Port map: [workflow_ports.tsv](/Users/alex/Library/Application%20Support/Symphony/workflow_ports.tsv)
- LaunchAgent definition: [com.alex.symphony.autostart.plist](/Users/alex/Library/LaunchAgents/com.alex.symphony.autostart.plist)
- Merge watcher logs: [merge-watcher.out.log](/Users/alex/Library/Logs/Symphony/merge-watcher.out.log) and [merge-watcher.err.log](/Users/alex/Library/Logs/Symphony/merge-watcher.err.log)

## 13. Internal design notes

More detailed local design docs created during this customization work live under:

- [2026-04-03-symphony-autostart-design.md](/Users/alex/Code/symphony/elixir/docs/superpowers/specs/2026-04-03-symphony-autostart-design.md)
- [2026-04-03-symphony-autostart.md](/Users/alex/Code/symphony/elixir/docs/superpowers/plans/2026-04-03-symphony-autostart.md)
- [2026-04-03-workflow-relocation-design.md](/Users/alex/Code/symphony/elixir/docs/superpowers/specs/2026-04-03-workflow-relocation-design.md)
- [2026-04-03-workflow-relocation.md](/Users/alex/Code/symphony/elixir/docs/superpowers/plans/2026-04-03-workflow-relocation.md)

## 14. Resulting operating model

The resulting end-to-end flow on this machine is:

1. Linear issue is assigned to you.
2. Symphony picks it up from the bound project and moves it to `Plan Progress`, even when the issue already has an attached PR.
3. Codex writes a plan into the Linear workpad.
4. The issue moves to `Plan Review`.
5. Human reviews the plan and moves the issue to `Code Progress`.
6. Codex implements on `feature/<issue>`.
7. Codex pushes the branch and opens a PR.
8. The issue moves to `Code Review`.
9. Human reviews and merges the PR on GitHub.
10. The local merge watcher moves the issue to `Done` and cleans the workspace.
