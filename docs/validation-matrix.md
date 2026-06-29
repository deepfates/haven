# Haven Validation Matrix

This document tracks whether the current Phoenix implementation actually serves
the Grei/Haven product story: a non-IDE ACP client for durable, inspectable agent
runs with explicit human decisions.

## Current Evidence

- Unit and integration tests: `mix test`
- Compile gate: `mix compile --warnings-as-errors`
- Final project gate: `mix precommit`
- Browser smoke: create a run, trigger a permission request, approve it, trigger
  an ACP file read, trigger a deterministic terminal command, create a run with
  an explicit workspace, and observe final `idle` status plus persisted timeline
  events in the in-app browser.

## Proven Now

### Inbox And Triage

Status: partially proven.

Evidence:

- `test/haven_web/live/inbox_live_test.exs` creates a run from the inbox and
  verifies navigation to run detail.
- The inbox create form captures title, workspace, and agent choice; LiveView
  tests verify selected workspace and configured agent are persisted into the
  run record.
- The same test verifies waiting, running, and idle runs render in separate
  attention lanes.
- Browser smoke verifies the rendered inbox can start a real run with an
  explicit workspace and that the run detail/ACP launch args reflect it.

Still missing:

- Agent/workspace persistence models and richer configuration management.
- Workspace path validation and browse/picker affordances.
- Archive/hide closed runs.
- Filtering beyond the fixed lanes.

### Run Timeline

Status: proven for the stub ACP lifecycle.

Evidence:

- `test/haven_web/live/run_live_test.exs` verifies startup events are persisted
  and survive a fresh LiveView mount.
- LiveView integration tests verify a non-message ACP `tool_call_update`
  notification is preserved as a durable timeline event.
- Browser smoke verifies the timeline renders protocol-shaped events during a
  real browser session.

Still missing:

- Rich protocol event normalization.
- Clear visual distinction between app-level and protocol-level events.

### Prompting And Control

Status: partially proven.

Evidence:

- LiveView integration tests submit the prompt form and verify `turn_started`,
  `user_message`, `agent_message_chunk`, and `turn_finished` events.
- Tests assert the run detail returns to visible `idle` after completion.
- LiveView integration tests cancel a run while it is blocked on permission and
  verify the outstanding permission is durably resolved as cancelled.
- LiveView integration tests cancel an open non-permission turn and verify the
  run returns to visible `idle`.

Still missing:

- Browser smoke for non-permission cancel; current executable evidence is
  LiveView-level.
- Strong suppression/correlation of late chunks from cancelled prompts.
- Retry or continue after recoverable failure.
- Disabled controls for all impossible states, not only waiting permissions.

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
- LiveView integration tests attempt a stale duplicate permission resolution and
  verify it is ignored without reopening the permission or changing the visible
  idle state.
- Browser smoke verifies the same flow through the real rendered UI.

Still missing:

- User identity or actor metadata for audit trails.
- Browser smoke for deny, cancel, stale, and reload paths; current browser smoke
  covers allow.

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
  process and records the selected agent, executable, and substituted workspace
  args in the timeline.
- Tests revealed and fixed a real status projection bug: `RunLive` now subscribes
  to run-status broadcasts as well as event broadcasts, so the header does not
  remain `running` after a completed turn.
- Tests revealed and fixed protocol transport noise from launching the stub via
  compiling `mix run`; the stub now starts with `mix run --no-compile --no-start`
  so Mix compiler output cannot corrupt the ACP JSON stream.
- LiveView integration tests trigger a non-zero stub exit and verify the run
  records `agent_process_exited`, fails the in-flight turn, and renders a
  visible `failed` state.
- Tests revealed and fixed a run-server restart-loop bug: terminal `failed` and
  `closed` runs are no longer auto-resurrected by LiveView mounts, and normal
  RunServer exits are not restarted by the supervisor.
- RunServer shutdown now explicitly tears down the ACP connection and port IO
  bridge.
- Event ordering and persistence are covered by `test/haven/events_test.exs`.

Still missing:

- Deliberate restart behavior after agent process crash.
- Resume from an existing persisted non-terminal run without spawning a
  duplicate or misleading live session.
- Concurrent multi-run behavior under realistic load.
- Production lifecycle policy for pruning or archiving failed and closed run
  servers.

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
  and verify writes land in the selected temporary workspace.
- `Haven.Terminals` runs short-lived non-interactive commands, captures stdout
  and stderr, reports exit status, and rejects terminal working directories
  outside the run workspace.
- LiveView integration tests drive the stub agent through real ACP
  `terminal/create`, `terminal/wait_for_exit`, `terminal/output`, and
  `terminal/release` requests, verify durable `terminal_*` events, verify the
  agent receives output and exit status, and verify the final turn returns to
  visible `idle`.
- Browser smoke verifies the rendered UI can trigger an ACP file read and a
  deterministic terminal command, with visible timeline events and final `idle`
  state.

Still missing:

- Real external agent coverage for file requests.
- Real external agent coverage for terminal requests.
- Permission policy around file reads and writes.
- File diff/artifact projections for review.
- PTY-style interactive terminal sessions.
- Executable evidence for `terminal/kill`.
- Configurable per-run capability grants.

## Not Proven Yet

These are not cosmetic gaps. They are core to the full Grei telos and should not
be counted as complete until there is executable evidence.

- Real external ACP agent integration beyond `priv/agent_stub.exs`.
- File read/write capability requests from a real external agent.
- Terminal capability requests from a real external agent.
- Interactive terminal behavior and executable `terminal/kill` evidence.
- Authentication flows for agents that require auth.
- Session load/resume/fork/list support when agents expose it.
- Explicit handling for malformed ACP frames.
- Browser smoke for agent death; current executable evidence is LiveView-level.
- Browser smoke for non-message session updates; current executable evidence is
  LiveView-level.
- Product-grade workspace and agent configuration UI.
- Audit metadata for who made a permission decision.

## Next Best Validation Work

1. Add a supervised fake ACP agent test harness that can stream partial chunks,
   request duplicate permissions, emit malformed frames, and simulate restart.
2. Add LiveView tests for deliberate restart and reload after process exit.
3. Connect the configurable command path to one real ACP-speaking agent and
   document the exact command/env contract.
4. Connect terminal capability handling to a real ACP-speaking agent and add
   explicit kill/interactive-terminal evidence.
5. Connect file capability handling to a real ACP-speaking agent.
6. Add browser smoke coverage for reload recovery and attention-lane movement,
   not just a single happy-path permission approval.
