# Haven Design Requirements

This document describes the product and system requirements for Haven. It is
intentionally not a code tour. The goal is to name what the app must be true to,
what user stories it should support, and where the current implementation proves
or fails those requirements.

## Product Thesis

Haven is a non-IDE ACP client for working with coding agents as durable,
inspectable runs.

The app is not primarily an editor plugin, a chat app, or a task runner. It is a
place where agent work can be started, watched, paused for human decisions,
resumed, audited, and compared across time. The interface should treat agent
activity as operational work with memory and consequences, not as ephemeral chat
transcript.

## Design Principles

1. The UI is an API for the user.
   Every surface should expose clear operations on runs: start, inspect, decide,
   resume, cancel, retry, archive, and compare. Visual design should make the
   state of work obvious without requiring protocol knowledge.

2. Protocol reality beats protocol vibes.
   The client should use ACP concepts and flows directly: initialize, session
   creation, prompting, session updates, permission requests, cancellation, file
   and terminal capabilities, and extension methods where needed.

3. Runs are durable first, live second.
   A LiveView may disconnect, a browser tab may close, and an agent process may
   crash. The run record and event log must remain the source of truth.

4. Human decisions are first-class.
   Permission requests are not modal annoyances. They are explicit workflow
   events with context, options, result, timing, and auditability.

5. The system should be honest about uncertainty.
   Failed processes, unsupported ACP methods, partial output, stale sessions,
   and permission deadlocks should be visible states, not hidden exceptions.

6. The app should avoid IDE assumptions.
   It may later integrate editors, repos, terminals, and files, but the core
   object is a run. A user should be able to use Haven from a browser without
   living inside an IDE.

## Primary Users

- A solo developer delegating coding tasks to one or more agents.
- A maintainer reviewing agent work before it touches a repository.
- A user who wants a persistent operations view over autonomous or
  semi-autonomous agent activity.
- A future team user who needs shared visibility, handoff, and audit trails.

## Core User Stories

### Inbox and Triage

- As a user, I can see all active runs and quickly identify which need attention.
- As a user, I can distinguish running, waiting, failed, idle, and closed runs.
- As a user, I can open the run that currently needs my decision.
- As a user, I can create a new run with a title, workspace, and agent choice.

### Run Timeline

- As a user, I can inspect the complete ordered history of a run.
- As a user, I can see my prompts, agent messages, tool activity, permission
  requests, permission decisions, failures, and completion states.
- As a user, I can reload the page and recover the same run state.
- As a user, I can distinguish protocol events from app-level events.

### Prompting and Control

- As a user, I can send a prompt to an active agent session.
- As a user, I can cancel an in-flight turn.
- As a user, I can tell whether a turn is actively running, blocked on me, or
  complete.
- As a user, I can retry or continue work after a recoverable failure.

### Permissions

- As a user, I can review an agent's requested action before granting access.
- As a user, I can see the tool name, raw input, options, and surrounding run
  context for the request.
- As a user, I can approve, deny, or cancel a permission request.
- As a user, I can later audit who decided what and when.

### Workspace Capabilities

- As an agent, I can request file reads, file writes, terminal creation, terminal
  output, command termination, and other ACP client capabilities.
- As a user, I can configure which capabilities are available for a run.
- As a user, I can see when a capability is unavailable rather than watching the
  run fail opaquely.

### Recovery

- As a user, I can see when an agent process exits or crashes.
- As a user, I can resume or restart a run when the protocol and agent support
  it.
- As a user, I can preserve the historical record even when the live process is
  gone.

## Required UX Surfaces

### Inbox

The inbox is the attention surface. It should be dense and operational, not a
marketing dashboard.

The inbox should be mobile-first and row-oriented. Runs should appear before
workspace and agent administration, because the user's first question is what
needs attention. Setup and policy controls should remain available but should
not dominate the first screen.

Required content:

- Run title.
- Workspace.
- Agent.
- Current status.
- Last meaningful event.
- Whether a permission or failure needs action.
- Recovery guidance that distinguishes continue, retry, restart, and review
  states before the user opens the run.
- Activity ordering by the latest meaningful event inside each operational lane.
- Start time and last update time.

Required actions:

- Create run.
- Open run.
- Archive or hide closed runs.
- Filter by status.

### Run Detail

The run detail page is both transcript and control room.

The default presentation should be conversation/activity first. On mobile, run
facts, filters, protocol details, file changes, terminal sessions, and audit
records should be disclosed on demand. On desktop, those same details may
expand into a side rail, but they must remain secondary to the current run
thread and next decision.

Required content:

- Header with title, status, workspace, agent, session id, and timestamps.
- Ordered event timeline.
- Current attention card, if any.
- Prompt composer when the run can accept input.
- Control actions: send, cancel, retry/restart where applicable.
- Protocol metadata available without overwhelming the main reading path.
- Timeline search by both raw event facts and rendered human labels.

Required behavior:

- Live updates while connected.
- Correct persisted state after reload.
- Disabled controls while waiting on permission or while no session exists.
- Explicit failed and closed states.

### Permission Card

Required content:

- Requested operation title.
- Tool call id.
- Tool status.
- Raw input.
- Available options.
- Link back to surrounding run context.

Required behavior:

- Approving resolves the exact pending ACP request.
- Denying resolves the exact pending ACP request.
- Canceling outstanding requests during run cancellation resolves them with a
  cancelled outcome.
- Stale or already-resolved permissions should not present active buttons.
- Permission requests and resolution attempts should also appear in a durable
  audit projection so users can review what was requested, which options were
  available, who or what resolved it, when it was requested and resolved, and
  whether the request was selected, cancelled, or ignored without spelunking raw
  timeline JSON.

## Protocol Requirements

The implementation should use `agent_client_protocol` for the real ACP client
connection path.

Required client-side ACP flows:

- `initialize`
- `session/new`
- `session/prompt`
- `session/cancel`
- `session/update` notifications
- `session/request_permission` requests

Required soon:

- File read/write client requests.
- Terminal create/output/release/kill/wait client requests.
- Authentication if the selected agent requires it.
- Session load/resume/fork/list if the agent supports those methods.
- Extension method and notification escape hatch.

Important protocol design note:

`agent_client_protocol` expects Elixir IO devices, while external agent
processes are naturally represented as Erlang Ports. A realistic Haven
implementation needs a maintained IO bridge, currently proven by
`Haven.PortIO`, or an upstream change that lets `ACP.Connection`
directly own a Port-like transport.

## System Requirements

### Runtime Shape

- A Phoenix application owns the browser UI.
- A supervised process owns each live run.
- A run process owns or supervises the ACP connection for that run.
- The ACP connection owns JSON-RPC request ids and response correlation.
- The app owns durable events, run lifecycle state, permission UX, and recovery.

### Persistence

Minimum durable models:

- `runs`
- `events`

Likely additional models:

- `workspaces`
- `agents`
- `permission_audits` for durable requested/resolved/ignored permission
  projections with actor class, selected option, request metadata, and raw
  input.
- `artifacts`
- `file_changes` for durable proposed/applied file write projections with
  bounded content and diff previews.
- `terminal_sessions` for durable terminal command/session projections; current
  implementation records bounded non-interactive terminal facts, while
  PTY-style interaction remains a later requirement.
- `run_snapshots` or projections for faster inbox loading

### Events

Events should be append-only. They should represent both protocol observations
and app decisions.

Required event families:

- Run lifecycle: created, initialized, session started, closed, failed.
- User input: prompt sent, cancel requested, permission decided.
- Agent output: message chunks, tool updates, plan updates.
- Client requests: permission, file, terminal, extension.
- Recovery: process exited, process crashed, resumed, restarted.

Open requirement:

Decide whether events store protocol payloads verbatim, normalized app payloads,
or both. The current implementation stores normalized payloads and should not be
assumed final.

### Supervision

Required supervision behavior:

- Run processes are started dynamically per run.
- Crashes are visible in run state.
- Restart policy should avoid infinite duplicate agent process starts.
- A crashed run should be recoverable by explicit user action or documented
  automatic policy.

Open requirement:

Define whether run processes are ephemeral live workers reconstructed from the
database, or durable process identities expected to survive until explicit run
closure.

## Non-Goals For The Next Milestone

- Full IDE feature parity.
- Rich diff review UI.
- Multi-user collaboration.
- Production authentication and authorization.
- Supporting every ACP unstable feature.
- Replacing a real code editor.

These may matter later, but they should not distort the core run/client design.

## Current Implementation Assessment

Proven:

- Phoenix/LiveView can present an inbox and run timeline.
- The inbox can create runs with explicit title, workspace, and agent choice.
- The inbox can narrow existing runs by operational lane, agent, workspace, and
  free-text facts while preserving updated lane counts.
- The inbox can save reusable workspace directories and select them when
  creating a run.
- Saved workspace entries can be edited in place, and the run picker uses the
  updated path when creating a run.
- Configured agent specs can provide executable, args, cwd, and env values with
  workspace substitution; launch events record cwd and env key names while
  redacting env values.
- Run creation rejects missing workspace directories before starting an agent
  process, and the inbox renders that validation failure in place.
- Terminal failed and closed runs can be archived from the inbox, hiding them
  from the default attention surface while preserving their run records and
  event history. Archived runs are review-only and cannot be directly started,
  reconnected, or retried.
- SQLite persistence is enough for narrow run/event proof.
- One `RunServer` per live run is a good fit.
- `agent_client_protocol` can own JSON-RPC request ids and response correlation.
- A Port-backed IO bridge can let `ACP.ClientSideConnection` talk to a spawned
  agent process, including preserving final unterminated output for diagnostics.
- Permission requests can suspend inside an ACP handler and resume from UI/API
  action.
- Permission decisions now carry a coarse actor class (`local_user` or
  `system`), which is enough to distinguish explicit user decisions from runtime
  cleanup but not enough for multi-user audit identity.
- Multiple simultaneous permission requests from one ACP prompt can be cancelled
  together without leaving an active decision card behind.
- Ordered session updates should be projected from the ACP stream subscription.
- Partial streamed agent chunks from a configured stdio ACP process can be
  projected and persisted in order.
- Multiple live runs can prompt concurrently without transcript or status
  cross-talk in the local ACP lifecycle.
- Deterministic ACP file read/write requests can be handled, logged, and scoped
  to the selected workspace.
- ACP file read and write requests are permission-gated before returning file
  content or touching the workspace: approval performs the capability request,
  denial blocks it, and both outcomes are durable timeline events.
- Write permission requests include bounded proposed-content and line-oriented
  diff previews, giving the user something concrete to inspect before
  approving. ACP file writes also create durable file-change projections that
  move from pending to applied, denied, failed, or cancelled and render on run
  detail after reload. The review surface summarizes pending, applied, and
  blocked changes and labels each proposed change with outcome-specific
  guidance. This is still a bounded preview surface, not a full multi-file
  artifact workspace.
- Runs can carry per-run capability policy for file reads, file writes, and
  terminal creation. File reads/writes support explicit ask, allow, or deny
  behavior plus optional workspace-relative path scopes; terminal creation
  supports ask, allow, or deny. Each applied automatic policy records a durable
  policy-decision event, and the run detail view exposes the effective policy
  after creation so users can inspect a run's current authority without
  reconstructing it from the creation form.
- Deterministic non-interactive ACP terminal create/wait/output/release requests
  can be handled, logged, scoped to the selected workspace, and projected back
  to the agent.
- The terminal-session review surface summarizes running, completed, and
  attention-needed sessions and labels individual terminal outcomes with
  inspectable guidance.
- Terminal creation can be approval-gated by per-run policy: the rendered
  permission card can approve the request and continue terminal execution, or
  deny it before a terminal process is spawned.
- Deterministic ACP terminal kill requests for direct child processes and
  shell-launched child processes can be handled, logged, followed by
  wait/output/release, and projected back to the agent.
- Disconnected idle run history can be viewed without silently spawning a new
  agent process.
- Disconnected idle history and failed persisted runs can be explicitly
  reconnected/restarted as fresh ACP processes.
- Runs that fail because the agent process exits during a turn can be restarted
  explicitly as fresh ACP processes while preserving the failed-turn history.
- Failed runs with a previous user prompt can retry the last prompt: Haven
  records retry intent, starts a fresh ACP session, resubmits the prompt, and
  preserves the failed transcript before the retry.
- Failed runs can also continue with a different prompt from the recovery card:
  Haven records continuation intent, starts a fresh ACP session, sends the new
  prompt, and preserves the failed transcript before the continuation.
- Configured external-agent commands can crash during a turn, restart as fresh
  ACP processes, and accept prompts after restart.
- Runs that lose an agent while permission is pending fail visibly and resolve
  the blocked permission as system-cancelled, avoiding a stale active decision
  card.
- Running turns are not promptable: the rendered UI disables prompt/sample
  controls while keeping cancellation available, and the run process rejects
  stale/direct concurrent prompt submissions as busy.
- Late session updates emitted after a local cancellation are recorded as
  ignored protocol updates instead of being appended as fresh agent transcript
  chunks.
- Malformed ACP output during startup is projected as a visible
  `agent_protocol_failed` run failure without an automatic restart loop.
- Malformed agent output after a successful ACP session has started is projected
  as a visible `agent_protocol_failed` run failure, and the active turn is
  failed instead of hanging indefinitely.
- The same post-start malformed-output failure path is proven through the
  configured external-agent command path using the fake ACP harness.
- The configured test-only fake ACP harness can exercise file-read and
  terminal-command ACP client callbacks through `mix haven.agent_probe`,
  reducing reliance on the built-in stub for capability validation.
- Timeline events expose a visible and machine-readable provenance marker
  (`app`, `user`, `agent`, `client`, `protocol`, or `runtime`) so users can
  distinguish app decisions from protocol and runtime activity.
- The run timeline can be filtered by provenance so users can inspect app,
  user, agent, client, protocol, and runtime events separately.
- Inbox latest-activity lookup resolves one newest event per requested run
  without caller-side full-history scans.

Not yet proven:

- Real external agents beyond the local stub and configured test-only fake
  harness.
- File capability handling against real non-test external agents.
- Product-grade file artifact review beyond the current bounded file-change
  projections and review-state summaries.
- Terminal capability handling against real non-test external agents.
- Interactive terminal sessions and process-tree kill behavior.
- ACP-native session resume policy.
- Multi-run load behavior beyond latest-event lookup.
- Long-running turn streaming under real output volume.
- Prompt-id-level correlation for late chunks; current cancellation suppression
  is session-level because ACP session updates do not carry prompt ids in the
  local evidence path.
- Backpressure, log compaction, and transcript projection performance.
- Security boundaries around workspace access, especially product-grade UI for
  richer configurable capability grants beyond the current create-form comma
  fields plus post-creation scope chips.
- Authentication flows and product-grade agent/workspace configuration,
  including OS-native workspace browse affordances; persisted workspace
  name/path records, persisted agent command definitions, basic inbox
  create/edit/delete, env injection for launched agents, and secret-redacted
  env/auth readiness labels exist, but interactive auth is not proven.
- Authenticated user identity on permission decisions; current actor metadata is
  local/system classification only.

Known implementation limitations:

- Permission request ids are app-level ids, not exposed protocol ids.
- Event types are trimmed and rejected if blank; event payloads are normalized
  to string-keyed JSON-style maps at append time and rejected if they contain
  non-JSON-compatible values, but formal per-event payload schemas are still
  missing.
- Archived runs can be pruned through an explicit tested context API and inbox
  UI, but there is no product retention schedule yet.
- The UI is operational but not yet product-quality.
- The stub agent is useful for deterministic tests but not representative of a
  full agent.
- `PortIO` still needs broader production hardening, though it now preserves
  final unterminated output for diagnostics.

## Design Questions To Resolve Next

1. What run status transitions are legal across live, disconnected, failed,
   closed, and restarted runs?
2. Should every ACP message be stored as a raw protocol event?
3. How should app-level events relate to raw ACP stream events?
4. What workspace permissions are granted by default?
5. Does Haven launch agents, connect to existing agents, or both?
6. How should a user choose an agent and configure its command/cwd/env?
7. What is the correct recovery behavior after a process crash?
8. What does "resume" mean when ACP support is absent?
9. Which controls belong in the inbox versus the run detail view?
10. What should be searchable: prompts, agent text, tool calls, files, runs?

## Recommended Next Milestone

The next milestone should connect one real ACP-speaking agent and harden the
client capability callbacks for file and terminal operations.

Acceptance criteria:

- A user can create a run backed by a real agent command.
- The app initializes an ACP session through `ACP.ClientSideConnection`.
- The user can send a prompt and see streamed session updates.
- The agent can request permission and receive the selected outcome.
- At least one file capability request is handled and logged.
- At least one terminal command is created, awaited, read, released, and logged.
- Agent process exit is represented as a stable run state, without duplicate
  automatic restarts.
