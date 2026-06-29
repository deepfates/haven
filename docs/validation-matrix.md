# Haven Validation Matrix

This document tracks whether the current Phoenix implementation actually serves
the Grei/Haven product story: a non-IDE ACP client for durable, inspectable agent
runs with explicit human decisions.

## Current Evidence

- Unit and integration tests: `mix test`
- Compile gate: `mix compile --warnings-as-errors`
- Final project gate: `mix precommit`
- Browser smoke: create a run, trigger a permission request, approve it, observe
  final `idle` status and persisted timeline in the in-app browser.

## Proven Now

### Inbox And Triage

Status: partially proven.

Evidence:

- `test/haven_web/live/inbox_live_test.exs` creates a run from the inbox and
  verifies navigation to run detail.
- The same test verifies waiting, running, and idle runs render in separate
  attention lanes.
- Browser smoke verifies the rendered inbox can start a real run.

Still missing:

- Agent selection.
- Workspace selection.
- Archive/hide closed runs.
- Filtering beyond the fixed lanes.

### Run Timeline

Status: proven for the stub ACP lifecycle.

Evidence:

- `test/haven_web/live/run_live_test.exs` verifies startup events are persisted
  and survive a fresh LiveView mount.
- Browser smoke verifies the timeline renders protocol-shaped events during a
  real browser session.

Still missing:

- Rich protocol event normalization.
- Tool activity beyond permission requests.
- Clear visual distinction between app-level and protocol-level events.

### Prompting And Control

Status: partially proven.

Evidence:

- LiveView integration tests submit the prompt form and verify `turn_started`,
  `user_message`, `agent_message_chunk`, and `turn_finished` events.
- Tests assert the run detail returns to visible `idle` after completion.

Still missing:

- Strong cancel semantics for an in-flight prompt.
- Retry or continue after recoverable failure.
- Disabled controls for all impossible states, not only waiting permissions.

### Permissions

Status: proven for one stub request/response flow.

Evidence:

- LiveView integration tests trigger a permission request, verify the active
  permission card, approve the exact `request_id`, and verify the final agent
  message.
- Browser smoke verifies the same flow through the real rendered UI.

Still missing:

- Deny path.
- Stale/already-resolved permission behavior.
- Cancellation of outstanding permissions during run cancellation.
- User identity or actor metadata for audit trails.

### Runtime And Persistence

Status: partially proven.

Evidence:

- A supervised `RunServer` owns each live run.
- Tests revealed and fixed a real status projection bug: `RunLive` now subscribes
  to run-status broadcasts as well as event broadcasts, so the header does not
  remain `running` after a completed turn.
- Event ordering and persistence are covered by `test/haven/events_test.exs`.

Still missing:

- Agent process crash/restart behavior.
- Resume from an existing persisted run without spawning a duplicate or
  misleading live session.
- Concurrent multi-run behavior under realistic load.
- Cleanup and lifecycle policy for closed run servers.

## Not Proven Yet

These are not cosmetic gaps. They are core to the full Grei telos and should not
be counted as complete until there is executable evidence.

- Real external ACP agent integration beyond `priv/agent_stub.exs`.
- File read/write client capability requests.
- Terminal create/output/release/kill/wait requests.
- Authentication flows for agents that require auth.
- Session load/resume/fork/list support when agents expose it.
- Explicit handling for unsupported ACP methods and malformed frames.
- Agent death that fails pending prompts instead of leaving the UI ambiguous.
- Product-grade workspace and agent configuration.
- Audit metadata for who made a permission decision.

## Next Best Validation Work

1. Add a supervised fake ACP agent test harness that can deterministically crash,
   hang, stream partial chunks, request duplicate permissions, and emit unknown
   update types.
2. Add LiveView tests for cancel, deny, stale permission buttons, and reload
   during a pending permission.
3. Add a real ACP-agent adapter path configurable per run instead of hard-coding
   the stub in `RunServer`.
4. Add file and terminal capability handling, first against deterministic fake
   requests, then against a real ACP-speaking agent.
5. Add browser smoke coverage for reload recovery and attention-lane movement,
   not just a single happy-path permission approval.
