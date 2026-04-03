# Local Customizations

This file documents the local, project-specific customizations made on top of the upstream `openai/symphony` checkout in this machine.

The goal of these changes is to make Symphony work as a local multi-project coding orchestrator for the following repos:

- `mf`
- `nest-core`
- `pack-ifc`

The upstream file [README.md](/Users/alex/Code/symphony/README.md) remains the source of truth for the base project. This document only covers local customization.

## 1. Repo-owned workflow files

Custom workflows are no longer stored centrally under `symphony/elixir/WORKFLOW.*.md`.

They now live inside each target repo so they can be versioned with the codebase and reused on other machines:

- [mf/.symphony/WORKFLOW.md](/Users/alex/Code/mf/.symphony/WORKFLOW.md)
- [nest-core/.symphony/WORKFLOW.md](/Users/alex/Code/nest-core/.symphony/WORKFLOW.md)
- [pack-ifc/.symphony/WORKFLOW.md](/Users/alex/Code/pack-ifc/.symphony/WORKFLOW.md)

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

## 3. Codex runtime customization

All project workflows explicitly run the local Codex app server with:

- model: `gpt-5.4`
- reasoning: `xhigh`
- service tier: `fast`

This is enforced in each workflow `codex.command` instead of relying only on global defaults.

## 4. Human plan-review gate

The workflows were changed so the agent does not start implementation immediately after writing a plan.

Current behavior:

1. Symphony picks up the Linear issue.
2. Codex writes the plan into the Linear workpad.
3. The issue moves to `In Review` and pauses.
4. A human reviews or edits the plan.
5. A human approves the plan by adding a Linear comment such as `approve plan`, `plan approved`, `批准计划`, or `继续开发`.
6. The issue is moved back to `In Progress`.
7. Codex resumes implementation.

This gate is implemented through the `Plan Review Gate` section in each custom workflow.

## 5. Git and PR policy

The custom workflows enforce a GitHub-review-based flow instead of direct pushes to integration branches.

Rules added:

- never commit directly to `main`, `master`, or `dev`
- create or reuse `feature/{{ issue.identifier }}`
- push the feature branch
- open a GitHub PR
- wait for human review and human merge

The review semantics were also clarified:

- `In Review` without a PR means plan review
- `In Review` with a PR means final code review

## 6. Project-specific workspace behavior

### `mf`

The `mf` workflow treats the repo as a root workspace with multiple child Git repos. It determines the owning repo before branching, committing, pushing, or opening a PR.

### `nest-core`

The `nest-core` workflow treats the repo as a single Rust repo and prefers local build/test entrypoints such as:

- `./scripts/build.sh`
- `cargo build`
- `cargo test`

Unlike the other two repos, `nest-core` now runs its spawned Codex sessions with:

- `thread_sandbox: danger-full-access`
- `turn_sandbox_policy.type: dangerFullAccess`

This repo-specific exception was added because `workspace-write` blocked `.git` writes needed for `git fetch`, feature branch creation, and PR-oriented Git operations inside the Symphony workspace.

### `pack-ifc`

The `pack-ifc` workflow now treats the repo root as the single owning Git repo and knows that the root also contains large local resource directories used for validation.

## 7. `pack-ifc` repo-root migration

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

## 8. Project-local startup commands

Each project now has its own local startup script that defaults to the repo-owned workflow:

- [mf/scripts/start-symphony.sh](/Users/alex/Code/mf/scripts/start-symphony.sh)
- [nest-core/scripts/start-symphony.sh](/Users/alex/Code/nest-core/scripts/start-symphony.sh)
- [pack-ifc/scripts/start-symphony.sh](/Users/alex/Code/pack-ifc/scripts/start-symphony.sh)

Current default UI ports:

- `mf` -> `4000`
- `nest-core` -> `4001`
- `pack-ifc` -> `4002`

Convenience npm entrypoints were also added:

- [mf/package.json](/Users/alex/Code/mf/package.json)
- [nest-core/package.json](/Users/alex/Code/nest-core/package.json)
- [pack-ifc/package.json](/Users/alex/Code/pack-ifc/package.json)

Usage:

```bash
cd /Users/alex/Code/<repo>
npm run symphony:start
```

## 9. Login-time autostart

A local macOS LaunchAgent was added so Symphony instances start automatically after login.

Key files:

- [symphony-autostart-supervisor.zsh](/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh)
- [symphony-autostart-instance.zsh](/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-instance.zsh)
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

## 10. Stable port mapping

The autostart supervisor maintains a stable workflow-to-port mapping in:

- [workflow_ports.tsv](/Users/alex/Library/Application%20Support/Symphony/workflow_ports.tsv)

Ports start at `4000` and are preserved for already-known workflows when possible, so adding a new workflow does not usually reshuffle existing ports.

## 11. Logs and runtime inspection

Useful runtime locations:

- LaunchAgent logs: [~/Library/Logs/Symphony](/Users/alex/Library/Logs/Symphony)
- Port map: [workflow_ports.tsv](/Users/alex/Library/Application%20Support/Symphony/workflow_ports.tsv)
- LaunchAgent definition: [com.alex.symphony.autostart.plist](/Users/alex/Library/LaunchAgents/com.alex.symphony.autostart.plist)

## 12. Internal design notes

More detailed local design docs created during this customization work live under:

- [2026-04-03-symphony-autostart-design.md](/Users/alex/Code/symphony/elixir/docs/superpowers/specs/2026-04-03-symphony-autostart-design.md)
- [2026-04-03-symphony-autostart.md](/Users/alex/Code/symphony/elixir/docs/superpowers/plans/2026-04-03-symphony-autostart.md)
- [2026-04-03-workflow-relocation-design.md](/Users/alex/Code/symphony/elixir/docs/superpowers/specs/2026-04-03-workflow-relocation-design.md)
- [2026-04-03-workflow-relocation.md](/Users/alex/Code/symphony/elixir/docs/superpowers/plans/2026-04-03-workflow-relocation.md)

## 13. Resulting operating model

The resulting end-to-end flow on this machine is:

1. Linear issue is assigned to you.
2. Symphony picks it up from the bound project.
3. Codex writes a plan into the Linear workpad.
4. Human reviews the plan.
5. Codex implements on `feature/<issue>`.
6. Codex pushes the branch and opens a PR.
7. Human reviews and merges on GitHub.
8. Symphony finishes the issue lifecycle.
