# Symphony Autostart Design

**Goal**

Automatically start every local `WORKFLOW.*.md` Symphony instance after macOS login, keep instances running, and assign web ports starting at `4000` with stable reuse for already-known workflows.

**Requirements**

- Discover workflows from `/Users/alex/Code/symphony/elixir/WORKFLOW.*.md`.
- Start all discovered workflows without editing the LaunchAgent every time a new workflow is added.
- Use ports starting at `4000`.
- Keep existing workflow-to-port mappings stable across reboots.
- Work with the current local environment, including `mise`, `codex`, and `LINEAR_API_KEY` from `~/.zshrc`.
- Be inspectable and easy to uninstall.

**Chosen Approach**

Use one macOS LaunchAgent to run a long-lived Symphony supervisor. The supervisor rescans the workflow directory on a short interval, maintains a stable workflow-to-port mapping file under `~/Library/Application Support/Symphony/`, and starts any missing Symphony instance through a dedicated instance launcher script.

This avoids per-workflow plist sprawl while still supporting future `WORKFLOW.*.md` files automatically. It also gives us a single place to manage logs, port allocation, and restart behavior.

**Components**

- `scripts/symphony-autostart-instance.zsh`
  Starts one Symphony process for a specific workflow and port, sourcing `~/.zshrc` first so local credentials and PATH are available.
- `scripts/symphony-autostart-supervisor.zsh`
  Discovers workflow files, maintains the stable port map, and ensures every configured workflow has a running Symphony process.
- `scripts/install-symphony-autostart.zsh`
  Installs and loads `~/Library/LaunchAgents/com.alex.symphony.autostart.plist`.
- `scripts/uninstall-symphony-autostart.zsh`
  Unloads and removes the LaunchAgent.

**Port Allocation**

- Base port is `4000`.
- The supervisor sorts workflow paths deterministically.
- If a workflow already has a saved port in `workflow_ports.tsv`, it keeps that port.
- New workflows receive the next free port.
- Removed workflows are dropped from the rewritten map so future new workflows can reuse freed ports.

**Runtime Behavior**

- LaunchAgent starts on login and keeps the supervisor alive.
- Supervisor rescans the workflow directory every few seconds.
- If a workflow process is missing, the supervisor relaunches it.
- Each workflow writes to its own stdout/stderr log files under `~/Library/Logs/Symphony/`.

**Failure Handling**

- Missing `LINEAR_API_KEY`, `mise`, workflow file, or Symphony binary causes the instance launcher to exit with a clear error message in logs.
- The supervisor does not crash if one workflow fails; it continues managing the rest and retries failed workflows on the next scan.

**Verification**

- Verify plist syntax with `plutil -lint`.
- Install the LaunchAgent and confirm it appears in `launchctl print`.
- Confirm `workflow_ports.tsv` is created and ports start at `4000`.
- Confirm each discovered workflow listens on its assigned port.
- Confirm adding a new `WORKFLOW.*.md` file gives it the next free port without changing existing mappings.
