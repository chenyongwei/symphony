# Workflow Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move each custom Symphony workflow into its owning repo and promote `/Users/alex/Code/pack-ifc` to be the Git repo root.

**Architecture:** Repo-owned `.symphony/WORKFLOW.md` files become the source of truth. Shared Symphony runtime scripts continue to live in the Symphony Elixir repo, but they discover workflows recursively from project repos.

**Tech Stack:** git, zsh scripts, macOS LaunchAgent, Symphony Elixir

---

### Task 1: Capture red-state migration checks

**Files:**
- Test: `/Users/alex/Code/mf/.symphony/WORKFLOW.md`
- Test: `/Users/alex/Code/nest-core/.symphony/WORKFLOW.md`
- Test: `/Users/alex/Code/pack-ifc/.symphony/WORKFLOW.md`
- Test: `/Users/alex/Code/pack-ifc/.git`

- [ ] **Step 1: Verify repo-local workflow files are absent**

Run:

```bash
test -f /Users/alex/Code/mf/.symphony/WORKFLOW.md
test -f /Users/alex/Code/nest-core/.symphony/WORKFLOW.md
test -f /Users/alex/Code/pack-ifc/.symphony/WORKFLOW.md
```

Expected: all commands fail before migration

- [ ] **Step 2: Verify pack-ifc root is not yet a Git repo**

Run:

```bash
git -C /Users/alex/Code/pack-ifc status -sb
```

Expected: `fatal: not a git repository`

### Task 2: Promote pack-ifc root to the Git repo root

**Files:**
- Modify: `/Users/alex/Code/pack-ifc/.git`
- Move: `/Users/alex/Code/pack-ifc/steel_ifc_stage1/*`

- [ ] **Step 1: Move Git metadata to the pack-ifc root**

Move `.git` from `steel_ifc_stage1/` to `/Users/alex/Code/pack-ifc/.git`.

- [ ] **Step 2: Move tracked project files to the new root**

Move the tracked project files and directories from `steel_ifc_stage1/` to `/Users/alex/Code/pack-ifc/`.

- [ ] **Step 3: Preserve untracked runtime artifacts**

Move `tmp/` to the new root if present, and leave local resource directories in place.

### Task 3: Relocate workflows into repo-owned .symphony directories

**Files:**
- Create: `/Users/alex/Code/mf/.symphony/WORKFLOW.md`
- Create: `/Users/alex/Code/nest-core/.symphony/WORKFLOW.md`
- Create: `/Users/alex/Code/pack-ifc/.symphony/WORKFLOW.md`
- Delete: `/Users/alex/Code/symphony/elixir/WORKFLOW.mf.md`
- Delete: `/Users/alex/Code/symphony/elixir/WORKFLOW.nest-core.md`
- Delete: `/Users/alex/Code/symphony/elixir/WORKFLOW.pack-ifc.md`

- [ ] **Step 1: Create per-repo .symphony directories**
- [ ] **Step 2: Move workflow content into repo-local WORKFLOW.md files**
- [ ] **Step 3: Update pack-ifc workflow wording for the new repo root**

### Task 4: Update start scripts and autostart discovery

**Files:**
- Modify: `/Users/alex/Code/mf/scripts/start-symphony.sh`
- Modify: `/Users/alex/Code/nest-core/scripts/start-symphony.sh`
- Modify: `/Users/alex/Code/pack-ifc/scripts/start-symphony.sh`
- Modify: `/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh`

- [ ] **Step 1: Point each project start script at its local .symphony workflow**
- [ ] **Step 2: Change supervisor discovery from central files to repo-local `.symphony/WORKFLOW*.md`**
- [ ] **Step 3: Exclude temporary Symphony workspaces and archive folders from discovery**

### Task 5: Reload and verify

**Files:**
- Test: `/Users/alex/Library/Application Support/Symphony/workflow_ports.tsv`
- Test: `/Users/alex/Library/LaunchAgents/com.alex.symphony.autostart.plist`

- [ ] **Step 1: Restart the autostart LaunchAgent**
- [ ] **Step 2: Verify new workflow paths are discovered**
- [ ] **Step 3: Verify pack-ifc root Git status, local workflow paths, and listening ports**
