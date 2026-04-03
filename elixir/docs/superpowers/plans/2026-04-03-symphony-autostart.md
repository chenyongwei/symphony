# Symphony Autostart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a login-time supervisor that automatically discovers and starts every local `WORKFLOW.*.md` Symphony instance with stable ports starting at `4000`.

**Architecture:** A single LaunchAgent runs a supervisor script inside the Symphony Elixir repo. The supervisor maintains a stable workflow-to-port map and uses a separate instance launcher to start or restart missing workflow processes.

**Tech Stack:** macOS LaunchAgent, zsh scripts, `mise`, Symphony Elixir CLI

---

### Task 1: Add design and runtime scripts

**Files:**
- Create: `/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-instance.zsh`
- Create: `/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh`

- [ ] **Step 1: Add the instance launcher**

Write a zsh script that:
- accepts `workflow` and `port`
- sources `~/.zshrc`
- validates `LINEAR_API_KEY`, `mise`, Symphony repo path, and workflow path
- `exec`s `mise exec -- ./bin/symphony --port <port> <workflow>`

- [ ] **Step 2: Add the supervisor**

Write a zsh script that:
- scans `/Users/alex/Code/symphony/elixir/WORKFLOW.*.md`
- maintains `~/Library/Application Support/Symphony/workflow_ports.tsv`
- preserves existing ports for known workflows
- assigns new ports starting from `4000`
- launches any missing workflow process through the instance launcher

- [ ] **Step 3: Make scripts executable**

Run:

```bash
chmod +x /Users/alex/Code/symphony/elixir/scripts/symphony-autostart-instance.zsh \
  /Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh
```

Expected: no output

### Task 2: Add LaunchAgent management

**Files:**
- Create: `/Users/alex/Code/symphony/elixir/scripts/install-symphony-autostart.zsh`
- Create: `/Users/alex/Code/symphony/elixir/scripts/uninstall-symphony-autostart.zsh`

- [ ] **Step 1: Add install script**

Write a zsh script that:
- writes `~/Library/LaunchAgents/com.alex.symphony.autostart.plist`
- points it at the supervisor script
- enables `RunAtLoad` and `KeepAlive`
- writes launchd logs to `~/Library/Logs/Symphony/`
- bootstraps and kickstarts the agent

- [ ] **Step 2: Add uninstall script**

Write a zsh script that:
- bootouts the LaunchAgent if loaded
- removes the plist

- [ ] **Step 3: Make scripts executable**

Run:

```bash
chmod +x /Users/alex/Code/symphony/elixir/scripts/install-symphony-autostart.zsh \
  /Users/alex/Code/symphony/elixir/scripts/uninstall-symphony-autostart.zsh
```

Expected: no output

### Task 3: Verify local behavior

**Files:**
- Test: `/Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh`
- Test: `/Users/alex/Code/symphony/elixir/scripts/install-symphony-autostart.zsh`

- [ ] **Step 1: Verify script syntax**

Run:

```bash
zsh -n /Users/alex/Code/symphony/elixir/scripts/symphony-autostart-instance.zsh
zsh -n /Users/alex/Code/symphony/elixir/scripts/symphony-autostart-supervisor.zsh
zsh -n /Users/alex/Code/symphony/elixir/scripts/install-symphony-autostart.zsh
zsh -n /Users/alex/Code/symphony/elixir/scripts/uninstall-symphony-autostart.zsh
```

Expected: no output

- [ ] **Step 2: Install and start the LaunchAgent**

Run:

```bash
/Users/alex/Code/symphony/elixir/scripts/install-symphony-autostart.zsh
```

Expected: LaunchAgent is loaded and kickstarted

- [ ] **Step 3: Validate launchd and ports**

Run:

```bash
plutil -lint /Users/alex/Library/LaunchAgents/com.alex.symphony.autostart.plist
launchctl print gui/$(id -u)/com.alex.symphony.autostart
cat "$HOME/Library/Application Support/Symphony/workflow_ports.tsv"
lsof -nP -iTCP:4000-4010 -sTCP:LISTEN | grep symphony
```

Expected: valid plist, running LaunchAgent, mapped workflows, and Symphony listeners starting at `4000`
