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

Required content:

- Run title.
- Workspace.
- Agent.
- Current status.
- Last meaningful event.
- Whether a permission or failure needs action.
- Start time and last update time.

Required actions:

- Create run.
- Open run.
- Archive or hide closed runs.
- Filter by status.

### Run Detail

The run detail page is both transcript and control room.

Required content:

- Header with title, status, workspace, agent, session id, and timestamps.
- Ordered event timeline.
- Current attention card, if any.
- Prompt composer when the run can accept input.
- Control actions: send, cancel, retry/restart where applicable.
- Protocol metadata available without overwhelming the main reading path.

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
- `permissions`
- `artifacts`
- `terminal_sessions`
- `files_changed`
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
- SQLite persistence is enough for narrow run/event proof.
- One `RunServer` per live run is a good fit.
- `agent_client_protocol` can own JSON-RPC request ids and response correlation.
- A Port-backed IO bridge can let `ACP.ClientSideConnection` talk to a spawned
  agent process.
- Permission requests can suspend inside an ACP handler and resume from UI/API
  action.
- Ordered session updates should be projected from the ACP stream subscription.
- Deterministic ACP file read/write requests can be handled, logged, and scoped
  to the selected workspace.
- Deterministic non-interactive ACP terminal create/wait/output/release requests
  can be handled, logged, scoped to the selected workspace, and projected back
  to the agent.
- Deterministic ACP terminal kill requests for direct child processes can be
  handled, logged, followed by wait/output/release, and projected back to the
  agent.
- Disconnected idle run history can be viewed without silently spawning a new
  agent process.
- Disconnected idle history and failed persisted runs can be explicitly
  reconnected/restarted as fresh ACP processes.
- Malformed ACP output during startup is projected as a visible
  `agent_protocol_failed` run failure without an automatic restart loop.

Not yet proven:

- Real external agents beyond the local stub.
- File capability handling against real external agents.
- Terminal capability handling against real external agents.
- Interactive terminal sessions and process-tree kill behavior.
- ACP-native session resume policy.
- Malformed ACP frame handling after a session has successfully started.
- Multi-run load behavior.
- Long-running turn streaming under real output volume.
- Backpressure, log compaction, and transcript projection performance.
- Security boundaries around workspace access.
- Authentication and product-grade agent/workspace configuration.

Known implementation limitations:

- Permission request ids are app-level ids, not exposed protocol ids.
- Event payload schema is informal.
- The UI is operational but not yet product-quality.
- The stub agent is useful for deterministic tests but not representative of a
  full agent.
- `PortIO` is minimal and should be hardened before production use.

## Design Questions To Resolve Next

1. What is the canonical run state machine?
2. Should every ACP message be stored as a raw protocol event?
3. How should app-level events relate to raw ACP stream events?
4. What workspace permissions are granted by default?
5. Does Haven launch agents, connect to existing agents, or both?
6. How should a user choose an agent and configure its command/env?
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
