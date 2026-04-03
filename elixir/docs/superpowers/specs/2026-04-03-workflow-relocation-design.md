# Workflow Relocation Design

**Goal**

Move each custom Symphony workflow into the corresponding project repo so the workflow can be versioned with the codebase and reused on other machines. As part of that change, promote `/Users/alex/Code/pack-ifc` to be the Git repo root instead of `/Users/alex/Code/pack-ifc/steel_ifc_stage1`.

**Chosen layout**

- `/Users/alex/Code/mf/.symphony/WORKFLOW.md`
- `/Users/alex/Code/nest-core/.symphony/WORKFLOW.md`
- `/Users/alex/Code/pack-ifc/.symphony/WORKFLOW.md`

**Key decisions**

- Keep Symphony runtime scripts in `/Users/alex/Code/symphony/elixir/scripts/` because they are orchestration infrastructure shared across repos.
- Change each project-level `start-symphony.sh` to default to the local `.symphony/WORKFLOW.md`.
- Change the autostart supervisor to discover `*/.symphony/WORKFLOW*.md` under `/Users/alex/Code`, while excluding temporary Symphony workspace copies and archive folders.
- Preserve stable ports starting at `4000` via the existing port map.
- Remove the old central workflow files from `/Users/alex/Code/symphony/elixir/` after migration to avoid duplicate startup.

**pack-ifc repo migration**

- Move the Git metadata from `/Users/alex/Code/pack-ifc/steel_ifc_stage1/.git` to `/Users/alex/Code/pack-ifc/.git`.
- Move the tracked project files (`README.md`, `src/`, `tests/`, `examples/`, packaging files) from `steel_ifc_stage1/` to the `pack-ifc/` root so the working tree still matches the repository history.
- Keep local resource directories such as `test-ifc/`, `.debug_wgkl_subset/`, `stage1_verify/`, and `即墨中学IFC/` at the repo root as local assets.
- Preserve existing untracked validation output by moving `tmp/` to the new root instead of deleting it.

**Verification**

- `git -C /Users/alex/Code/pack-ifc status -sb` works from the new root.
- All three repos contain `.symphony/WORKFLOW.md`.
- Project `start-symphony.sh` scripts resolve to the new local workflow path.
- Autostart discovers only repo-local workflows.
- LaunchAgent restarts cleanly and serves the three current workflows on `4000`, `4001`, and `4002`.
