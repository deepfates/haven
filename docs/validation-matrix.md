# Haven Validation Matrix

This document tracks whether the current Phoenix implementation actually serves
the production-grade Haven product story: a non-IDE ACP client for durable,
inspectable agent runs with explicit human decisions.

## Current Evidence

- Unit and integration tests: `mix test`
- Compile gate: `mix compile --warnings-as-errors`
- Final project gate: `mix precommit`
- Runtime migration gate before browser smoke: `MIX_ENV=dev mix
  haven.pending_migrations` must report no pending migrations for the dev
  database that backs `http://127.0.0.1:4000/`.
- Runtime HTTP smoke: with the dev server running, `MIX_ENV=dev mix
  haven.runtime_smoke` renders the real inbox/run pages, creates a run through
  `/dev/runs` in a disposable workspace, triggers and resolves a generic
  permission request, approves ACP file read/write requests, verifies the
  written file, runs a deterministic terminal command, and verifies the thread,
  decision, and evidence disclosure surfaces in rendered HTML.
- Agent probe harness: `mix haven.agent_probe --report` can produce durable JSON
  evidence artifacts with explicit `--expect-event` acceptance checks; see
  `docs/probes/README.md`.
- LiveView integration: malformed ACP startup output records
  `agent_protocol_failed`, marks the run `failed`, and does not restart the
  agent process.
- LiveView integration: inbox hierarchy tests verify runs render before
  workspace/agent setup panels, and run-detail tests verify the conversation
  thread exists with filter controls disclosed behind a summary element.
- Browser smoke: create a run, trigger a permission request, approve it, trigger
  and approve an ACP file read, trigger and approve an ACP file write, trigger a
  deterministic terminal command, cancel an open non-permission turn, create a
  run with an ACP terminal kill for a direct process, create a run with an
  explicit workspace, reject a missing workspace at run creation, reload a
  pending permission and deny it, cancel a waiting permission turn, submit a
  stale permission decision and observe ignored resolution, reload disconnected
  history, explicitly reconnect that history, verify post-reconnect transcript
  projection across a resumed turn, restart after an actual agent crash,
  trigger malformed ACP startup output, trigger malformed ACP output after a
  successful session start, create a run with file-read allow, file-write deny,
  and terminal-create deny policy, create a run with file-read/file-write path
  scopes and inspect those effective scopes on run detail, and observe final
  status plus persisted timeline events in the in-app browser.

## Falsification Discipline

Evidence for a user story should try to disprove the story, not only confirm a
happy path. For every production-grade claim, keep these checks current:

- State the claim narrowly enough that it could fail.
- Run at least one negative or adversarial case: missing workspace, stale
  permission decision, denied capability policy, malformed ACP output, crashed
  agent, reload/reconnect, unsupported real-agent capability, or another case
  that would falsify the claim.
- Verify the actual browser/runtime database before browser smoke with
  `MIX_ENV=dev mix haven.pending_migrations`; test database migrations do not
  prove the running app at port 4000 can render.
- Run `MIX_ENV=dev mix haven.runtime_smoke` before treating a local UI change as
  runtime-verified. It is an automated rendered-HTML smoke for the dev server,
  not a substitute for visual browser inspection when layout, responsiveness, or
  real browser interaction behavior is the claim.
- Prefer persisted state checks after live UI actions: reload the browser,
  inspect durable events/projections, and confirm the state still holds.
- Record useful failures as negative evidence. A failed real-agent probe with
  `tool_call_only_capability_gap`, an ACP preflight failure, or an ignored stale
  permission is evidence about the boundary of what Haven does and does not
  prove.
- Do not promote a story from "partially proven" to "proven" unless the evidence
  covers the realistic happy path and the defined failure paths.

## Proven Now

### Inbox And Triage

Status: partially proven.

Evidence:

- `test/haven_web/live/inbox_live_test.exs` creates a run from the inbox and
  verifies navigation to run detail.
- The inbox create form captures title, workspace, and agent choice; LiveView
  tests verify selected workspace and configured agent are persisted into the
  run record.
- Saved workspaces are stored in SQLite with a name and normalized directory
  path; LiveView tests verify the inbox picker can create a run from a saved
  workspace, editing the workspace updates the picker/run path, and deleting
  the workspace removes it from the picker.
- Persisted agent configurations are stored in SQLite and appear in the inbox
  agent picker; LiveView tests verify a run can be created with a persisted
  agent key.
- The inbox has a basic Agent Setup form for saving a persisted ACP command
  with key, executable, args, cwd, and env values; LiveView tests and browser
  smoke verify the saved key appears in the run picker and can create a run.
- Saved agent setup rows separate launch readiness from ACP proof: LiveView
  tests verify resolvable commands show executable/arg/env-key metadata without
  leaking env values, while missing executables render as blocked before a run
  is started.
- The inbox can edit and delete persisted agent command definitions; LiveView
  tests verify updated keys replace old picker options and deleted keys
  disappear from run creation.
- Data-layer and LiveView tests verify run creation rejects missing workspace
  directories before any run process starts.
- The same test verifies waiting, running, and idle runs render in separate
  attention lanes.
- LiveView tests verify inbox rows expose explicit attention labels and primary
  actions for runs needing human decisions or recovery, so users can distinguish
  permission/failure work without opening each run.
- LiveView tests verify inbox rows project the latest meaningful run event and
  refresh that activity when a new event arrives without requiring a run status
  change.
- Data-layer tests verify latest inbox activity is resolved as one newest event
  per requested run, including duplicate and missing run ids, instead of
  requiring callers to scan full run event histories.
- LiveView tests verify inbox rows expose operational process-state hints for
  connected, disconnected, stale-decision, interrupted, failed, and closed runs,
  so persisted status is not mistaken for current agent liveness.
- LiveView tests verify the inbox can filter the attention surface to All,
  Needs You, Running, or History while preserving lane counts and empty states.
- LiveView tests verify the inbox can search visible run facts across title,
  workspace path, agent key, status, attention state, and latest activity while
  preserving lane counts and clear/no-match states.
- LiveView tests verify the inbox has explicit agent and workspace facets, so
  users managing many agents across folders can narrow runs without encoding
  those facts into free-text search; lane counts update through the facets.
- LiveView tests verify inbox search includes operational state text such as
  `not connected`, making stale work findable without opening every run.
- Browser smoke verifies the rendered inbox can start a real run with an
  explicit workspace and that the run detail/ACP launch args reflect it.
- Browser smoke verifies a run waiting on permission moves into the rendered
  `Needs You` lane, then returns to `History` after approval.
- Browser smoke verifies a missing workspace path stays on the inbox, renders
  `must be an existing directory`, and does not add the run to history.
- Data-layer and LiveView integration tests verify terminal `failed`/`closed`
  runs can be archived, active runs cannot be archived, and archive decisions
  preserve run events while hiding the run from the default inbox.
- Data-layer tests verify archived runs are operationally read-only: direct
  start, ensure-started, reconnect, and retry entry points all return
  `{:error, :archived_run}` without appending new lifecycle events.
- LiveView integration tests verify archived runs remain intentionally
  inspectable through an Archived inbox filter with archived timestamps, instead
  of becoming invisible durable records.
- Browser smoke verifies a failed run can be archived from History and
  disappears from the inbox without deleting its run record.
- Saved workspace rows now show derived readiness and run usage, including
  missing-on-disk folders plus active and archived run counts, so multi-folder
  triage exposes operational state without opening each run.

Still missing:

- Richer workspace configuration metadata beyond path readiness and run usage
  (for example repo branch, trust/auth scope, or OS-native folder identity).
- OS-native workspace browse affordances.
- Richer filtering beyond operational lanes, agent/workspace facets, and
  free-text search.

### Run Timeline

Status: proven for the stub ACP lifecycle.

Evidence:

- `test/haven_web/live/run_live_test.exs` verifies startup events are persisted
  and survive a fresh LiveView mount.
- LiveView integration tests verify the run header exposes title-adjacent run
  identity facts: agent key, session id, created timestamp, and updated
  timestamp.
- LiveView integration tests verify a non-message ACP `tool_call_update`
  notification is preserved as a durable timeline event.
- LiveView integration tests verify disconnected idle history renders without
  spawning a new agent process or appending synthetic live events.
- LiveView integration tests verify an explicit reconnect/restart request starts
  a fresh ACP process for disconnected idle history and failed persisted runs.
- LiveView integration tests verify disconnected and failed runs expose a
  main-thread recovery card whose Reconnect/Restart action starts the fresh ACP
  process while preserving the existing transcript.
- Browser smoke verifies the timeline renders protocol-shaped events during a
  real browser session, that disconnected history is visibly read-only, and that
  clicking Reconnect appends recovery and startup events.
- Browser smoke verifies a prompt-triggered non-message ACP `tool_call_update`
  renders as a `Protocol` timeline event with the expected tool id and title,
  then returns the run to `idle` with prompt controls enabled.
- LiveView integration tests and browser smoke verify timeline events carry
  explicit provenance labels and `data-event-kind` markers for app, user, agent,
  client, protocol, and runtime events.
- LiveView integration tests verify timeline controls can filter persisted
  events by provenance without mutating the run event log.
- LiveView integration tests verify the run timeline can search persisted
  activity by event type and payload content without mutating the event log,
  including paired tool-call result evidence.
- Event append now normalizes nested payload keys to strings before storage and
  PubSub broadcast, then rejects non-JSON-compatible values. Data-layer tests
  verify atom-keyed nested maps and lists are persisted and delivered as
  JSON-shaped payloads, and invalid terms fail before storage.
- Event append serializes sequence allocation per run in-process and retries the
  database unique-index conflict path. Data-layer tests verify concurrent
  append pressure preserves contiguous per-run sequence numbers without losing
  payloads.

Still missing:

- Rich protocol event normalization.
- Formal per-event payload schemas beyond the current durable string-key
  JSON-compatible payload contract.
- Rich grouping beyond provenance/search facets.

### Prompting And Control

Status: partially proven.

Evidence:

- LiveView integration tests submit the prompt form and verify `turn_started`,
  `user_message`, `agent_message_chunk`, and `turn_finished` events.
- A test-only fake ACP harness is launched through the configured external-agent
  command path and verifies partial streamed chunks are appended durably in
  order.
- Agent probe integration tests launch the same configured external-agent
  harness and verify durable file-read and terminal-command events through the
  probe path, not only through the built-in `stub-acp` agent.
- Tests assert the run detail returns to visible `idle` after completion.
- LiveView integration tests cancel a run while it is blocked on permission and
  verify the outstanding permission is durably resolved as cancelled.
- LiveView integration tests cancel an open non-permission turn and verify the
  run returns to visible `idle`.
- LiveView integration tests and browser smoke verify prompt controls are
  disabled while a turn is running, cancel remains available, and controls
  reopen after the cancellation returns the run to `idle`.
- LiveView integration tests verify disabled prompt controls explain why input
  is unavailable for disconnected idle, disconnected waiting, disconnected
  running, live running, failed, closed, and waiting-on-decision states, while
  ready idle runs show no blocking notice.
- LiveView integration tests verify disabled prompt, sample, and cancel
  controls carry element-level explanations, while enabled controls do not keep
  stale disabled-state tooltips.
- LiveView integration tests verify recoverable disconnected and failed states
  expose the next Reconnect/Restart action in the conversation path, not only in
  secondary controls.
- LiveView integration tests verify failed runs with a previous user prompt
  expose `Retry last prompt`; clicking it starts a fresh ACP session, records
  `turn_retry_requested`, resubmits the prompt, receives the agent response, and
  returns the run to `idle` while preserving the prior failed transcript.
- LiveView integration tests verify stale/direct prompt submission while a turn
  is already running is rejected as `{:error, :busy}` instead of starting a
  second concurrent turn.
- LiveView integration tests run two live runs concurrently, send separate
  prompts to each, and verify status, visible transcript, and persisted events
  remain isolated by run id.
- LiveView integration tests verify that late session updates after user
  cancellation are recorded as ignored protocol updates instead of being
  appended as fresh agent transcript chunks.

Still missing:

- Prompt-id-level correlation of late chunks when agents provide enough
  metadata; current suppression is session-level after cancellation.
- Continue semantics for recoverable failures where the next user intent is not
  simply resubmitting the last prompt.

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
- LiveView integration tests verify active permission cards expose the exact
  request id, tool call id, tool status, and option ids for generic agent
  permissions, file reads, and terminal creation before the user decides.
- LiveView integration tests verify active permission cards also expose the
  run's effective read, write, terminal, and path-scope authority, so decisions
  can be made with policy context in the same surface.
- Browser smoke verifies the same allow flow through the real rendered UI,
  including a rendered `permission_resolved` payload with
  `"actor": "local_user"`.
- Browser smoke verifies a waiting permission survives a page reload and can be
  denied from the rendered card, producing the denied agent response and final
  `idle` state.
- Browser smoke verifies cancellation while waiting on permission removes the
  card, records a local-user cancelled permission resolution, suppresses the
  late cancelled agent update, and returns the run to `idle`.
- Browser smoke verifies a stale duplicate permission decision records
  `permission_resolution_ignored` with `reason: not_pending`, preserves
  `actor: local_user` and the attempted `option_id`, keeps the run `idle`, and
  does not recreate the pending permission card.
- Permission requests now create durable `permission_audits` rows that are
  updated on allow, deny, local-user cancellation, and system cancellation.
  LiveView integration tests verify the run detail sidebar renders the audit
  projection and that rows preserve request id, kind, title, raw input,
  available options, selected option, outcome, actor class, and cancellation or
  stale-resolution reason.
- Stale duplicate permission decisions now create an ignored audit row instead
  of mutating the already-resolved request, making attempted late decisions
  reviewable without reopening the active permission flow.

Still missing:

- Authenticated user identity for audit trails; current metadata distinguishes
  actor class, not a specific person.

### Runtime And Persistence

Status: partially proven.

Evidence:

- A supervised `RunServer` owns each live run.
- `Haven.Agents` resolves the built-in `stub-acp` command and configured agent
  keys from application env.
- Configured agent executables are resolved either as absolute executable paths
  or via `PATH`, and missing executables fail as explicit
  `{:missing_executable, command}` errors before the port bridge starts.
- `HAVEN_AGENTS_JSON` can configure real ACP agent commands at runtime without
  editing Elixir source/config files.
- `Haven.Agents.create_agent_config/1` persists ACP agent command definitions
  in SQLite, and `Haven.Agents.available/0` merges persisted configs with
  runtime config for run creation.
- `Haven.Workspaces.create_workspace/1` persists reusable workspace entries in
  SQLite and validates that saved paths are existing directories.
- The inbox can create persisted agent command definitions through the rendered
  UI, including args and env text entry.
- The `Haven.Agents` context can update and delete persisted agent command
  definitions, and the inbox exposes those operations.
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
  compiling `mix run`; the built-in stub now starts through `elixir` with the
  app's current BEAM code paths so Mix compiler/build-lock output cannot
  corrupt the ACP JSON stream.
- LiveView integration tests trigger a non-zero stub exit and verify the run
  records `agent_process_exited`, fails the in-flight turn, and renders a
  visible `failed` state.
- LiveView integration tests verify an agent disappearance while a permission
  decision is pending fails the run and resolves the permission as cancelled by
  the `system` actor, even when the port exit status is not available yet.
- LiveView integration tests crash a live agent, click Restart on that same
  failed run, and verify a fresh ACP process/session starts.
- A configured fake ACP harness can crash on demand; LiveView integration
  verifies Restart launches a fresh configured ACP process/session and accepts a
  prompt after restart.
- Tests revealed and fixed a run-server restart-loop bug: terminal `failed` and
  `closed` runs are no longer auto-resurrected by LiveView mounts, and normal
  RunServer exits are not restarted by the supervisor.
- Tests and browser smoke verify LiveView mounts no longer auto-start
  disconnected idle runs; old run history renders with controls disabled and a
  `not connected` process state.
- Tests and browser smoke verify explicit reconnect/restart appends
  `run_reconnect_requested`, starts a fresh ACP process, and reconnects prompt
  controls.
- LiveView integration tests and browser smoke verify disconnected waiting runs
  with stale durable permission requests render decision buttons disabled, offer
  Reconnect, system-cancel the stale permission during reconnect, and start a
  fresh ACP process without leaving the old permission card active.
- LiveView integration tests and browser smoke verify disconnected running runs
  with an unterminated turn offer Reconnect, append a system `turn_failed`
  event for the stale turn, start a fresh ACP process, and reopen prompt
  controls without pretending the old turn is still live.
- LiveView integration tests and browser smoke verify the post-reconnect
  transcript remains readable across resumed work: the old prompt, explicit
  reconnect boundary, system `turn_failed`, new user prompt, and new agent
  response all render together in sequence.
- Tests and browser smoke verify terminal run archival hides old failed/closed
  work from the default inbox while keeping durable run events.
- Browser smoke verifies a run that actually recorded `agent_process_exited`
  and `turn_failed` can be restarted from the rendered run detail, then reloads
  with two process/session starts and final `idle` connected state.
- LiveView integration tests verify malformed ACP startup output records
  `agent_protocol_failed`, marks the run `failed`, renders visibly, and does not
  restart the malformed agent process.
- Browser smoke verifies malformed ACP startup output through the rendered run
  detail: status remains `failed`, controls are disabled, process state is
  `not connected`, runtime `agent_protocol_failed` is visible, and clicking
  Restart appends `run_reconnect_requested` plus a second runtime failure
  instead of hiding the error.
- LiveView integration tests and browser smoke verify malformed agent output
  after a successful ACP session has started records `agent_protocol_failed`,
  fails the active turn with `malformed_agent_output`, marks the run `failed`,
  and renders the failure in the timeline.
- A configured fake ACP harness can emit a malformed frame after session startup;
  LiveView integration verifies the same `agent_protocol_failed` and
  `turn_failed` projection through the configured external-agent command path.
- The `Run` schema now constrains persisted run statuses to the canonical
  vocabulary: `idle`, `initializing`, `running`, `waiting`, `failed`, and
  `closed`. Data-layer tests verify invalid statuses are rejected on both run
  creation and status updates.
- Direct `start_run/2` now refuses terminal `failed` and `closed` history with
  `{:error, :terminal_run}` and does not append lifecycle events. Data-layer
  tests preserve explicit reconnect/restart as the intentional recovery path.
- RunServer shutdown now explicitly tears down the ACP connection and port IO
  bridge.
- Event ordering and persistence are covered by `test/haven/events_test.exs`.
- `Haven.Runs.prune_archived_before/1` provides an explicit retention boundary
  for archived records. Data-layer tests verify it deletes only archived runs
  older than a cutoff and cascades their event history while preserving active
  and recent archived runs.

Still missing:

- ACP session resume semantics; current reconnect starts a fresh process/session.
- Broader concurrent multi-run behavior under realistic external-agent load.
- Product-level retention policy, scheduling, and UI around archived run pruning.

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
- Per-run file capability policy can include workspace-relative path scopes.
  LiveView integration tests verify out-of-scope reads and writes are denied
  before file content is returned or workspace writes occur, even when the
  broader file capability decision is `allow`. Empty path scope lists are
  treated as unrestricted workspace access, matching the inbox UI's blank scope
  fields.
- LiveView integration tests verify write permission requests include bounded
  proposed-content and line-oriented diff previews for human review, including
  independent truncation markers for large writes.
- LiveView integration tests verify file-write permission cards render a
  structured proposed-change review with path, change id, diff kind, byte
  counts, content preview, and diff preview before approval, while preserving
  the durable file-change projection.
- ACP file writes now create durable `file_changes` rows at request time with
  path, local change id, pending/applied/denied/failed/cancelled status, diff
  kind, byte counts, bounded proposed-content preview, and bounded diff
  preview. Data-context tests verify applied, denied, failed, and cancelled
  lifecycle states. LiveView integration tests verify the run detail sidebar
  starts empty, shows a pending proposed write before approval, updates it to
  applied with the resolved path after approval, and shows denied writes with
  their permission error. Browser smoke creates a run from the inbox with blank
  file-write scopes, triggers the write-file sample, verifies a pending
  file-change projection plus approval card, approves the write, verifies the
  projection becomes applied with a resolved path, reloads the page, and
  verifies the applied projection persists.
- LiveView integration tests verify the file-change review surface summarizes
  pending, applied, and blocked change counts, and labels each recorded change
  as needing review, applied, or blocked with outcome-specific guidance.
- `Haven.Terminals` runs short-lived non-interactive commands, captures stdout
  and stderr, reports exit status, and rejects terminal working directories
  outside the run workspace.
- LiveView integration tests drive the stub agent through real ACP
  `terminal/create`, `terminal/wait_for_exit`, `terminal/output`, and
  `terminal/release` requests, verify durable `terminal_*` events, verify the
  agent receives output and exit status, and verify the final turn returns to
  visible `idle`.
- LiveView integration tests verify terminal creation can be approval-gated by
  per-run policy: approval continues terminal create/wait/output/release, while
  denial returns a permission error without emitting `terminal_created`.
- LiveView integration tests verify terminal-create permission cards render a
  structured proposed-terminal review with command, args, working directory,
  and environment key names before approval.
- LiveView integration tests drive the stub agent through real ACP
  `terminal/kill` for a direct `sleep` process, then verify durable kill, wait,
  output, release, and final turn events.
- `test/haven/terminals_test.exs` verifies terminal kill recursively terminates
  a shell-launched background `sleep` child, not only the direct shell process.
- LiveView integration tests drive the stub agent through ACP `terminal/kill`
  for a shell-launched child process and verify durable kill, wait, output,
  final agent message, release, and final `idle` projection.
- Browser smoke verifies the rendered UI can trigger permission-gated ACP file
  read and write requests, approve them through the rendered permission card,
  see the proposed write content before approval, and trigger a deterministic
  terminal command, plus an ACP terminal kill for a direct process, with visible
  timeline events and final `idle` state.
- Per-run capability policies can be selected when creating a run. LiveView
  integration tests verify file reads can be auto-allowed, file writes can be
  auto-denied, terminal creation can be approval-gated, and terminal creation
  can be auto-denied without opening a permission card or spawning a terminal
  process, while durable `capability_policy_applied` events record automatic
  policy decisions. Browser smoke verifies the same policy controls and
  rendered run timeline behavior. The run detail facts panel also renders the
  effective policy, with LiveView and browser coverage verifying the
  post-creation inspection path. Inbox and run-detail LiveView tests verify
  file path scopes can be entered during run creation, normalized into
  workspace-relative policy lists, and inspected after creation. Run detail
  tests also verify scoped and unrestricted path grants render as explicit
  policy chips in both the facts panel and pending decision card.
- `mix haven.agent_probe` now exercises a configured ACP agent through Haven's
  real run lifecycle, including run creation, ACP boot/session setup, prompting,
  optional permission resolution, per-run capability policy, durable event
  reporting, explicit `--expect-event` acceptance checks, and field-level
  `--expect-event-field EVENT:payload.path=value` checks. The probe can write a
  pretty JSON report with `--report`, giving real-agent validation a durable
  artifact format instead of a copied terminal transcript. Current automated
  coverage runs this probe against `stub-acp`, including file policy allow,
  scoped file policy deny, and terminal-create policy deny stories, and against
  the configured test-only fake ACP harness for file-read, terminal-command,
  and approval-gated terminal-command stories.
  Real-agent proof still requires running the same probe against a non-test
  configured ACP command with expectations for the specific story being
  validated.
- Probe reports support literal and environment-derived redaction before
  printing or writing JSON, which lowers the risk of committing real-agent
  evidence artifacts that contain secrets echoed by agents or tools.
- Probe reports intended as real-agent evidence can require a real-agent guard;
  the guard rejects the built-in `stub-acp` and the configured local test
  harness scripts before writing a passing acceptance artifact.
- `mix haven.agent_probe --list-agents` inventories configured agents, command
  resolution, static real-agent probe eligibility, rejection reasons, and
  redacted environment key names before a user attempts a real-agent probe. This
  is intentionally weaker than evidence: a command can resolve and still fail
  ACP preflight.
- `mix haven.agent_probe --list-agents --preflight` can turn probe candidacy
  into an explicit ACP boot check by creating short durable runs for eligible
  candidates and verifying `agent_initialized` plus `agent_session_started`
  before a user attempts a full evidence report.
- `mix haven.agent_probe --list-agents --registry` fetches the public ACP
  Registry and prints npx-backed `HAVEN_AGENTS_JSON` suggestions, so Haven can
  guide users toward real ACP adapters such as `claude-acp`, `codex-acp`, and
  `gemini` instead of relying on local shell placeholders.
- `mix haven.agent_probe --save-registry-agent AGENT_ID` persists one registry
  suggestion into the same Agent Setup table used by the UI, reducing the gap
  between discovery and a preflighted saved command without treating the saved
  command itself as evidence.
- The inbox Agent Setup panel surfaces the same probe-readiness distinction for
  saved agent configs, showing whether a saved command is only a static probe
  candidate or a rejected local harness/invalid command, rendering basic boot,
  field-checked file-read, file-write approval, terminal approval, and
  terminal-denial `--require-real-agent` report commands only for eligible probe
  candidates. Those generated commands mirror the missing production-grade
  evidence stories, explicitly warn that they are not ACP evidence until
  preflight or a generated probe passes, and never render environment values.
- Browser smoke verifies the Agent Setup panel also surfaces the public
  registry discovery command with `--registry` and warns that registry commands
  download and run third-party code before probing.
- Local inventory on this machine currently finds saved `/bin/sh -c cat`
  commands that are runnable non-test probe candidates, but they are not
  ACP-proven and do not satisfy the real-agent evidence requirement.
- A short `--require-real-agent` probe against
  `browser-candidate-1782737117083` starts `/bin/sh -c cat` but fails during
  ACP initialization with `agent_protocol_failed` / `Method not found`, proving
  that static probe candidacy is not enough to claim real-agent integration.
- Local `--list-agents --preflight --timeout 2000` now reports all saved
  `/bin/sh -c cat` candidates as `preflight: failed` with last event
  `agent_protocol_failed`, preserving durable failed preflight runs for
  inspection.
- Local registry discovery succeeds with `npx` installed and surfaces current
  npx-backed ACP adapters from the official registry, but no suggested adapter
  should be treated as evidence until it has a passing `docs/probes/*.json`
  report artifact.
- A registry-configured `codex-acp` command passed Haven preflight locally:
  `agent_initialized` and `agent_session_started` were recorded for a durable
  run through `npx @agentclientprotocol/codex-acp@1.0.1`.
- `mix haven.agent_probe --save-registry-agent codex-acp` now persists that
  registry suggestion into the local Agent Setup table; local preflight against
  the saved config passes, proving the registry-to-saved-agent workflow.
- `docs/probes/codex-acp-basic.json` is a committed passing
  `--require-real-agent` report from `npx @agentclientprotocol/codex-acp@1.0.1`
  against the disposable workspace `/private/tmp/haven-acp-smoke`. It proves a
  basic real external ACP turn: initialization, session start, user prompt,
  streamed agent message chunks, an unknown `usage_update` session update
  preserved as `agent_update_unknown`, and `turn_finished`.
- `docs/probes/codex-acp-file-tool-call.json` is a committed passing
  `--require-real-agent` report showing `codex-acp` can inspect a disposable
  workspace file and return a sentinel, but it does so through ACP
  `tool_call`/`tool_call_update` session updates rather than Haven's
  `fs/read_text_file` client request handler.
- A current `/tmp` attempt to require `file_read_requested`,
  `capability_policy_applied`, and `file_read_succeeded` against saved
  `codex-acp` fails with `missing_expected_events`: the agent still reads the
  file via a generic terminal `tool_call`, so it does not satisfy the
  Haven-mediated `fs/*` proof requirement.
- Failed probe reports now include diagnostics when missing Haven-mediated
  client capability events coincide with observed ACP `tool_call` /
  `tool_call_update` activity. The current saved `codex-acp` file-read attempt
  records this as `tool_call_only_capability_gap`, making the boundary explicit
  in both CLI output and JSON reports.
- `docs/probes/codex-acp-terminal-tool-call.json` is a committed passing
  `--require-real-agent` report showing `codex-acp` can execute a terminal
  command and return a sentinel, but it does so through ACP
  `tool_call`/`tool_call_update` session updates rather than Haven's
  `terminal/create`, `terminal/output`, and related client request handlers.
- Haven now wraps the upstream Elixir ACP client-side decoder so newer/unknown
  `session/update` variants are persisted as raw protocol events instead of
  crashing the connection. This was required by `codex-acp`, which currently
  emits `usage_update`.
- Haven redacts agent thought chunks into a single `agent_thought_redacted`
  marker per turn so real-agent probe reports and browser timelines do not
  persist raw model scratchpad text.
- The run timeline now renders ACP `tool_call` / `tool_call_update` file and
  terminal activity as first-class reviewable evidence: file path, command,
  working directory, status, exit code, and bounded output preview are projected
  without requiring users to inspect raw JSON.
- Matching `tool_call` starts and `tool_call_update` results are paired into one
  review card in the timeline, so long real-agent runs show an action and its
  result together while orphan updates remain visible as standalone protocol
  evidence.
- Haven-mediated `fs/*` and `terminal/*` client capability events now render as
  structured timeline evidence instead of raw JSON: file paths, resolved paths,
  command arguments, terminal ids, byte counts, exit statuses, and permission
  errors are projected as labeled fields.
- ACP terminal commands now also create durable `terminal_sessions` rows with
  terminal id, command, args, cwd, executable, environment key names, OS pid,
  lifecycle status, exit status, output byte count, bounded output preview, and
  cleanup timestamps. Data-context tests verify bounded output storage and
  killed/exited/released lifecycle semantics; LiveView integration tests verify
  these rows are created and updated through real stub ACP terminal
  create/wait/output/kill/release flows.
- The run detail sidebar now renders durable terminal sessions as an operational
  fact surface with command, terminal id, status, args, working directory,
  executable, exit status, output bytes, env key names, and bounded output
  preview. Browser smoke creates a run, triggers the terminal sample, verifies
  the rendered terminal session, reloads the page, and verifies the same
  persisted projection remains visible.
- LiveView integration tests verify the terminal session surface summarizes
  running, completed, and attention-needed session counts, and labels each
  terminal session with outcome-specific guidance for running, exited, and
  failed states.
- `mix haven.probe_reports` validates committed `docs/probes/*.json` artifacts
  and is part of `mix precommit`, so real-agent evidence requirements are a
  gate rather than only a documentation convention. Committed reports can now
  require payload-field facts as well as event types, so future Haven-mediated
  `fs/*` / `terminal/*` evidence can assert details like requested path,
  terminal command, and exit status. Reports that claim Haven-mediated
  `file_*` or `terminal_*` expected events now require matching field-level
  expectations for those event types, so type-only capability evidence is not
  accepted.

Still missing:

- Real non-test external agent coverage for Haven-mediated file requests
  (`fs/read_text_file` / `fs/write_text_file`).
- Real non-test external agent coverage for Haven-mediated terminal requests
  (`terminal/create`, `terminal/output`, `terminal/wait_for_exit`,
  `terminal/release`, and `terminal/kill`).
- Product-grade file artifact review; current evidence is a durable bounded
  `file_changes` projection with review counts/outcome hints for
  Haven-mediated writes, structured Haven-mediated client capability event
  projections, and grouped compact `tool_call` projections for real
  `codex-acp` file/terminal activity.
- PTY-style interactive terminal sessions.
- More expressive scoped-policy editing and grant modeling beyond the current
  create-form comma fields plus post-creation scope chips.

## Not Proven Yet

These are not cosmetic gaps. They are core to the production-grade Haven telos
and should not be counted as complete until there is executable evidence.

- Haven-mediated file read/write capability requests from a real non-test
  external agent.
- Haven-mediated terminal capability requests from a real non-test external
  agent.
- Interactive terminal behavior.
- Authentication flows for agents that require auth; configured env can pass
  secrets to launched agents, but no interactive auth flow is proven.
- Session load/resume/fork/list support when agents expose it.
- Product-grade workspace and agent configuration UI beyond saved rows,
  workspace readiness summaries, agent launch readiness, and agent inventory.
- Authenticated user identity for permission decisions.

## Next Best Validation Work

1. Find or build a non-test ACP-speaking adapter that exercises Haven-mediated
   `fs/*` and `terminal/*` client requests, then commit passing
   `--require-real-agent` reports for those stories.
2. Add interactive-terminal evidence once the terminal model moves beyond
   bounded non-interactive command execution.
