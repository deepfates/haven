# Selected Workspace Summary Smoke

Date: 2026-07-01

Purpose: verify the Start Run form gives users immediate folder identity before launching work across many saved workspaces.

Target: `http://127.0.0.1:4000/`

Observed after selecting the saved workspace `Haven repo branch smoke`:

- `#new-run-selected-workspace` rendered inside the Start Run form.
- Summary text included the workspace name: `Haven repo branch smoke`.
- `#new-run-selected-workspace-path-state` text: `Ready`.
- `#new-run-selected-workspace-branch` text: `Branch codex/elixir-cutover`.
- `#new-run-selected-workspace-path` text: `/Users/deepfates/Hacking/github/deepfates/haven`.
- `#new-run-selected-workspace-usage` text: `145 active runs · 3 archived runs`.

Verification commands:

- `mix test test/haven_web/live/inbox_live_test.exs`

