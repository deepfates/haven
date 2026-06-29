# Haven Validation Matrix

This document tracks whether the current Phoenix implementation actually serves
the Grei/Haven product story: a non-IDE ACP client for durable, inspectable agent
runs with explicit human decisions.

## Current Evidence

- Unit and integration tests: `mix test`
- Compile gate: `mix compile --warnings-as-errors`
- Final project gate: `mix precommit`
- LiveView integration: malformed ACP startup output records
  `agent_protocol_failed`, marks the run `failed`, and does not restart the
  agent process.
- Browser smoke: create a run, trigger a permission request, approve it, trigger
  and approve an ACP file read, trigger and approve an ACP file write, trigger a
  deterministic terminal command, cancel an open non-permission turn, create a
  run with an ACP terminal kill for a direct process, create a run with an
  explicit workspace, reject a missing workspace at run creation, reload
  disconnected history, explicitly reconnect that history, restart after an
  actual agent crash, trigger malformed ACP output after a successful session
  start, and observe final status plus persisted timeline events in the in-app
  browser.

## Proven Now

### Inbox And Triage

Status: partially proven.

Evidence:

- `test/haven_web/live/inbox_live_test.exs` creates a run from the inbox and
  verifies navigation to run detail.
- The inbox create form captures title, workspace, and agent choice; LiveView
  tests verify selected workspace and configured agent are persisted into the
  run record.
- Data-layer and LiveView tests verify run creation rejects missing workspace
  directories before any run process starts.
- The same test verifies waiting, running, and idle runs render in separate
  attention lanes.
- Browser smoke verifies the rendered inbox can start a real run with an
  explicit workspace and that the run detail/ACP launch args reflect it.
- Browser smoke verifies a run waiting on permission moves into the rendered
  `Needs You` lane, then returns to `History` after approval.
- Browser smoke verifies a missing workspace path stays on the inbox, renders
  `must be an existing directory`, and does not add the run to history.
- Data-layer and LiveView integration tests verify terminal `failed`/`closed`
  runs can be archived, active runs cannot be archived, and archive decisions
  preserve run events while hiding the run from the default inbox.
- Browser smoke verifies a failed run can be archived from History and
  disappears from the inbox without deleting its run record.

Still missing:

- Agent/workspace persistence models and richer configuration management.
- Workspace browse/picker affordances.
- Filtering beyond the fixed lanes.

### Run Timeline

Status: proven for the stub ACP lifecycle.

Evidence:

- `test/haven_web/live/run_live_test.exs` verifies startup events are persisted
  and survive a fresh LiveView mount.
- LiveView integration tests verify a non-message ACP `tool_call_update`
  notification is preserved as a durable timeline event.
- LiveView integration tests verify disconnected idle history renders without
  spawning a new agent process or appending synthetic live events.
- LiveView integration tests verify an explicit reconnect/restart request starts
  a fresh ACP process for disconnected idle history and failed persisted runs.
- Browser smoke verifies the timeline renders protocol-shaped events during a
  real browser session, that disconnected history is visibly read-only, and that
  clicking Reconnect appends recovery and startup events.
- LiveView integration tests and browser smoke verify timeline events carry
  explicit provenance labels and `data-event-kind` markers for app, user, agent,
  client, protocol, and runtime events.

Still missing:

- Rich protocol event normalization.
- Rich filtering or grouping by event provenance.

### Prompting And Control

Status: partially proven.

Evidence:

- LiveView integration tests submit the prompt form and verify `turn_started`,
  `user_message`, `agent_message_chunk`, and `turn_finished` events.
- A test-only fake ACP harness is launched through the configured external-agent
  command path and verifies partial streamed chunks are appended durably in
  order.
- Tests assert the run detail returns to visible `idle` after completion.
- LiveView integration tests cancel a run while it is blocked on permission and
  verify the outstanding permission is durably resolved as cancelled.
- LiveView integration tests cancel an open non-permission turn and verify the
  run returns to visible `idle`.
- LiveView integration tests and browser smoke verify prompt controls are
  disabled while a turn is running, cancel remains available, and controls
  reopen after the cancellation returns the run to `idle`.
- LiveView integration tests verify stale/direct prompt submission while a turn
  is already running is rejected as `{:error, :busy}` instead of starting a
  second concurrent turn.
- LiveView integration tests verify that late session updates after user
  cancellation are recorded as ignored protocol updates instead of being
  appended as fresh agent transcript chunks.

Still missing:

- Prompt-id-level correlation of late chunks when agents provide enough
  metadata; current suppression is session-level after cancellation.
- Retry or continue after recoverable failure.
- Disabled controls for every impossible state and control combination beyond
  the covered waiting/running/disconnected states.

### Permissions

Status: proven for the stub allow, deny, cancel, reload, and stale-resolution
flows.

Evidence:

- LiveView integration tests trigger a permission request, verify the active
  permission card, approve the exact `request_id`, and verify the final agent
  message.
- LiveView integration tests deny the exact `request_id` and verify the stub
  reports that the requested action will not be taken.
- LiveView integration tests reload a waiting run and verify the pending
  permission card is reconstructed from durable events.
- LiveView integration tests cancel a waiting run and verify the pending
  permission is resolved with a cancelled outcome.
- A configured fake ACP harness can issue two simultaneous permission requests
  for one prompt; LiveView integration verifies user cancellation resolves both
  requests and suppresses late cancelled output.
- LiveView integration tests attempt a stale duplicate permission resolution and
  verify it is ignored without reopening the permission or changing the visible
  idle state.
- LiveView integration tests verify permission decisions record an actor class:
  explicit allow, deny, reload-then-allow, user cancellation, and stale
  duplicate attempts record `local_user`; agent crash cleanup of a pending
  permission records `system`.
- Browser smoke verifies the same allow flow through the real rendered UI,
  including a rendered `permission_resolved` payload with
  `"actor": "local_user"`.

Still missing:

- Authenticated user identity for audit trails; current metadata distinguishes
  actor class, not a specific person.
- Browser smoke for deny, cancel, stale, and reload paths; current browser smoke
  covers allow and its actor metadata.

### Runtime And Persistence

Status: partially proven.

Evidence:

- A supervised `RunServer` owns each live run.
- `Haven.Agents` resolves the built-in `stub-acp` command and configured agent
  keys from application env.
- LiveView integration tests verify that an unknown run agent records
  `agent_start_failed`, marks the run `failed`, and renders that failure without
  falling back to the stub.
- LiveView integration tests verify a configured agent key launches the ACP
  process, substitutes the selected workspace in args/cwd/env, starts the
  process in the configured cwd, passes configured env to the spawned process,
  and records the selected agent, executable, args, cwd, and env key names in
  the timeline without recording env values.
- Tests revealed and fixed a real status projection bug: `RunLive` now subscribes
  to run-status broadcasts as well as event broadcasts, so the header does not
  remain `running` after a completed turn.
- Tests revealed and fixed protocol transport noise from launching the stub via
  compiling `mix run`; the stub now starts with `mix run --no-compile --no-start`
  so Mix compiler output cannot corrupt the ACP JSON stream.
- LiveView integration tests trigger a non-zero stub exit and verify the run
  records `agent_process_exited`, fails the in-flight turn, and renders a
  visible `failed` state.
- LiveView integration tests verify an agent disappearance while a permission
  decision is pending fails the run and resolves the permission as cancelled by
  the `system` actor, even when the port exit status is not available yet.
- LiveView integration tests crash a live agent, click Restart on that same
  failed run, and verify a fresh ACP process/session starts.
- Tests revealed and fixed a run-server restart-loop bug: terminal `failed` and
  `closed` runs are no longer auto-resurrected by LiveView mounts, and normal
  RunServer exits are not restarted by the supervisor.
- Tests and browser smoke verify LiveView mounts no longer auto-start
  disconnected idle runs; old run history renders with controls disabled and a
  `not connected` process state.
- Tests and browser smoke verify explicit reconnect/restart appends
  `run_reconnect_requested`, starts a fresh ACP process, and reconnects prompt
  controls.
- Tests and browser smoke verify terminal run archival hides old failed/closed
  work from the default inbox while keeping durable run events.
- Browser smoke verifies a run that actually recorded `agent_process_exited`
  and `turn_failed` can be restarted from the rendered run detail, then reloads
  with two process/session starts and final `idle` connected state.
- LiveView integration tests verify malformed ACP startup output records
  `agent_protocol_failed`, marks the run `failed`, renders visibly, and does not
  restart the malformed agent process.
- LiveView integration tests and browser smoke verify malformed agent output
  after a successful ACP session has started records `agent_protocol_failed`,
  fails the active turn with `malformed_agent_output`, marks the run `failed`,
  and renders the failure in the timeline.
- A configured fake ACP harness can emit a malformed frame after session startup;
  LiveView integration verifies the same `agent_protocol_failed` and
  `turn_failed` projection through the configured external-agent command path.
- RunServer shutdown now explicitly tears down the ACP connection and port IO
  bridge.
- Event ordering and persistence are covered by `test/haven/events_test.exs`.

Still missing:

- ACP session resume semantics; current reconnect starts a fresh process/session.
- Concurrent multi-run behavior under realistic load.
- Production lifecycle policy for pruning archived run records and old event
  logs.

### Workspace Capabilities

Status: partially proven for deterministic ACP requests.

Evidence:

- `Haven.WorkspaceFiles` handles `fs/read_text_file` and `fs/write_text_file`
  requests inside the run workspace and rejects path escapes before touching the
  filesystem.
- `test/haven/workspace_files_test.exs` verifies read slicing, write behavior,
  and outside-workspace rejection.
- LiveView integration tests drive the stub agent through real ACP
  `fs/read_text_file` and `fs/write_text_file` requests, verify durable
  `file_read_*` and `file_write_*` events, verify the agent receives responses,
  verify reads pause on a local permission decision before file content is
  returned, verify write denial leaves the selected temporary workspace
  unchanged, and verify approved writes land in that workspace.
- LiveView integration tests verify write permission requests include a bounded
  proposed-content preview for human review, including a truncation marker for
  large writes.
- `Haven.Terminals` runs short-lived non-interactive commands, captures stdout
  and stderr, reports exit status, and rejects terminal working directories
  outside the run workspace.
- LiveView integration tests drive the stub agent through real ACP
  `terminal/create`, `terminal/wait_for_exit`, `terminal/output`, and
  `terminal/release` requests, verify durable `terminal_*` events, verify the
  agent receives output and exit status, and verify the final turn returns to
  visible `idle`.
- LiveView integration tests drive the stub agent through real ACP
  `terminal/kill` for a direct `sleep` process, then verify durable kill, wait,
  output, release, and final turn events.
- Browser smoke verifies the rendered UI can trigger permission-gated ACP file
  read and write requests, approve them through the rendered permission card,
  see the proposed write content before approval, and trigger a deterministic
  terminal command, plus an ACP terminal kill for a direct process, with visible
  timeline events and final `idle` state.

Still missing:

- Real external agent coverage for file requests.
- Real external agent coverage for terminal requests.
- Full file diff/artifact projections for review; current evidence is only a
  bounded proposed-content preview on write permission requests.
- PTY-style interactive terminal sessions.
- Process-tree kill semantics for shell-launched children.
- Configurable per-run capability grants.

## Not Proven Yet

These are not cosmetic gaps. They are core to the full Grei telos and should not
be counted as complete until there is executable evidence.

- Real external ACP agent integration beyond `priv/agent_stub.exs`.
- File read/write capability requests from a real external agent.
- Terminal capability requests from a real external agent.
- Interactive terminal behavior and process-tree kill semantics.
- Authentication flows for agents that require auth; configured env can pass
  secrets to launched agents, but no interactive auth flow is proven.
- Session load/resume/fork/list support when agents expose it.
- Browser smoke for malformed ACP startup output; current executable evidence is
  LiveView-level.
- Browser smoke for non-message session updates; current executable evidence is
  LiveView-level.
- Product-grade workspace and agent configuration UI.
- Authenticated user identity for permission decisions.

## Next Best Validation Work

1. Extend the fake ACP agent harness beyond partial streaming, duplicate
   permission pressure, and malformed post-start frames so it can simulate
   restart.
2. Connect the configurable command/cwd/env path to one real ACP-speaking agent and
   document any agent-specific auth contract.
3. Connect terminal capability handling to a real ACP-speaking agent and add
   process-tree kill/interactive-terminal evidence.
4. Connect file capability handling to a real ACP-speaking agent.
5. Add browser smoke coverage for reload recovery and non-happy-path permission
   flows, not just approval.
