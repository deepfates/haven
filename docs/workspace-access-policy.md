# Workspace Access Policy

Haven's current workspace access policy is intentionally local and
workspace-rooted. It is a product boundary, not only an implementation detail.

## Policy

- The selected run workspace is the root of file and terminal authority.
- File read and write requests are resolved relative to the workspace and must
  stay inside that workspace after path expansion.
- File path scopes narrow file authority to workspace-relative paths. A blank
  scope means all paths inside the selected workspace, not the whole machine.
- Terminal creation is controlled separately from file reads and writes.
- Terminal working directories must stay inside the selected workspace.
- Automatic allow or deny decisions are recorded as durable
  `capability_policy_applied` events.
- Human decisions are recorded as durable permission audit rows.
- Agent environment variable names may be shown for launch clarity, but values
  must not be rendered in setup, launch, run detail, or evidence surfaces.

## Current Limits

- The policy is local-user oriented; authenticated multi-user identity is not
  implemented.
- Rich grant editing beyond create-time comma-separated path scopes is not
  implemented.
- Interactive auth flows for agents are not proven.
- Real non-test external agents have not yet proven Haven-mediated `fs/*` or
  `terminal/*` client capability handling.
