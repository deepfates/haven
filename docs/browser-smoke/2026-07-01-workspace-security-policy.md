# Browser Smoke: Workspace Security Policy

Date: 2026-07-01

Purpose: verify that workspace access is surfaced as a user-visible product
policy, not only as implementation-level path checks.

Target: `http://127.0.0.1:4000/`

Checks:

- Inbox rendered without a pending migration or server error page.
- Start-run advanced controls exposed `#new-run-security-boundary`.
- The start-run policy block rendered:
  - `Workspace security boundary`
  - `Files are resolved inside the selected workspace root.`
  - `Blank path scopes mean all workspace paths; scoped paths narrow access.`
  - `Terminal working directories must stay inside the workspace.`
- Existing run detail at
  `http://127.0.0.1:4000/runs/3c55080b-a4bf-4073-9f8a-b35dd970a5f4`
  exposed `#run-capability-policy` and `#run-security-boundary`.
- The run-detail policy block rendered the same root-boundary, blank-scope, and
  terminal-cwd semantics for the persisted run.

Outcome: pass.

