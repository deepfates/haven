# Agent Probe Evidence

This directory is for committed `mix haven.agent_probe --report` artifacts from
real, non-stub ACP agents.

The deterministic `stub-acp` agent proves the harness. A report only counts as
production-grade Haven real-agent evidence when all of the following are true:

- The `agent` field names a configured agent other than `stub-acp`.
- The `run_id` field non-blankly names the durable Haven run that produced the
  report.
- The report was generated with `--require-real-agent`, so `real_agent_evidence`
  is present with `accepted: true`.
- The report was produced through Haven's run lifecycle, not by talking directly
  to the agent process.
- The ordered `events` list includes the minimum Haven lifecycle spine:
  `run_created`, `agent_process_started`, `agent_initialized`,
  `agent_session_started`, `turn_started`, `user_message`, and `turn_finished`.
- The `run_created` event payload matches the report's `agent` and `workspace`,
  and the `user_message` event payload matches the report's `prompt`, so
  committed evidence cannot splice lifecycle rows from a different run story.
- `redactions` is present as a list. Literal redactions record only
  `{source: "literal"}`; environment-derived redactions record the environment
  variable name but never the raw secret value.
- `expected_events` names the lifecycle or capability events required by the
  story being validated.
- `missing_expected_events` is empty.
- `expected_event_fields`, when present, names payload facts required by the
  story being validated, such as requested paths, terminal commands, exit
  statuses, and permission decisions.
- Expected event field paths may use either the generated report form
  (`path`) or the CLI/documentation form (`payload.path`); both refer to the
  event payload.
- `missing_expected_event_fields` is empty.
- Reports that claim Haven-mediated `file_*` or `terminal_*` capability events
  in `expected_events` must include matching `expected_event_fields` entries
  for those event types; type-only capability evidence is not accepted.
- `status` is `idle` or `closed`; a failed run cannot count as positive
  production-grade evidence even if it contains some expected events.
- Positive reports must not include `tool_call_only_capability_gap` diagnostics
  or `unsupported_client_capabilities`; those declarations belong in named
  negative boundary reports under `docs/probe-failures`.
- The ordered `events` list shows the relevant ACP lifecycle, prompt, permission,
  file, terminal, failure, or recovery events.

Some agents expose file and terminal activity as ACP `tool_call` /
`tool_call_update` session updates instead of calling the client request
methods that Haven mediates directly. Those reports are useful real-agent
evidence for visibility and timeline projection, but they must not be counted as
proof of Haven-mediated `fs/*` or `terminal/*` permission handling unless the
expected events include the corresponding `file_*`, `terminal_*`, and
permission events.

When a probe expects Haven-mediated capability events but only observes generic
ACP tool calls, failed reports may include a `tool_call_only_capability_gap`
diagnostic. Treat that as useful negative evidence: the agent did work through
ACP, but Haven did not exercise its direct `fs/*` or `terminal/*` client
handlers for that story. Committed failure reports must also include
`unsupported_client_capabilities`, naming the mediated capability family that
the real agent class did not exercise.

Examples:

```bash
mix haven.agent_probe --list-agents --workspace /path/to/repo
mix haven.agent_probe --list-agents --proof-commands --workspace /path/to/repo
mix haven.agent_probe --list-agents --preflight --workspace /path/to/repo
mix haven.agent_probe --list-agents --registry --preflight --proof-commands --workspace /path/to/repo

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "summarize this workspace" \
  --require-real-agent \
  --redact-env ANTHROPIC_API_KEY \
  --expect-event agent_initialized \
  --expect-event agent_session_started \
  --expect-event turn_finished \
  --report docs/probes/my-agent-basic.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "read README.md" \
  --require-real-agent \
  --file-read-paths README.md,docs \
  --resolve-permissions allow \
  --expect-event permission_requested \
  --expect-event permission_resolved \
  --expect-event file_read_succeeded \
  --expect-event turn_finished \
  --expect-event-field file_read_succeeded:payload.path=README.md \
  --report docs/probes/my-agent-file-read.json \
  --failure-report docs/probe-failures/my-agent-file-mediated-negative.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "run the test command" \
  --require-real-agent \
  --terminal-create-policy ask \
  --resolve-permissions allow \
  --expect-event permission_requested \
  --expect-event permission_resolved \
  --expect-event terminal_created \
  --expect-event terminal_output_succeeded \
  --expect-event turn_finished \
  --expect-event-field terminal_create_requested:payload.command=mix \
  --expect-event-field terminal_output_succeeded:payload.exit_status=0 \
  --report docs/probes/my-agent-terminal-approval.json \
  --failure-report docs/probe-failures/my-agent-terminal-mediated-negative.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "run the test command" \
  --require-real-agent \
  --terminal-create-policy allow \
  --expect-event terminal_created \
  --expect-event terminal_output_succeeded \
  --expect-event terminal_released \
  --expect-event turn_finished \
  --expect-event-field terminal_create_requested:payload.command=mix \
  --expect-event-field terminal_output_succeeded:payload.exit_status=0 \
  --report docs/probes/my-agent-terminal.json \
  --failure-report docs/probe-failures/my-agent-terminal-mediated-negative.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "try to open a terminal" \
  --require-real-agent \
  --terminal-create-policy deny \
  --expect-event terminal_create_requested \
  --expect-event capability_policy_applied \
  --expect-event terminal_create_denied \
  --expect-event turn_finished \
  --expect-event-field terminal_create_requested:payload.command=mix \
  --expect-event-field capability_policy_applied:payload.decision=deny \
  --report docs/probes/my-agent-terminal-denied.json \
  --failure-report docs/probe-failures/my-agent-terminal-denied-mediated-negative.json
```

Use `--list-agents` first when preparing real-agent evidence. It prints every
configured agent, whether its command resolves on this machine, whether it can
count as a `--require-real-agent` candidate, and whether full proof commands
are available on demand. The inventory shows environment variable names but not
their values.

Use `--list-agents --proof-commands` when you want the full acceptance-command
set for a candidate. It prints basic boot, Haven-mediated file read,
permission-approved file write, permission-approved terminal, and denied
terminal guard probes. These commands are intentionally stricter than launch
readiness: they include expected event and field checks so missing `fs/*` or
`terminal/*` client-capability stories fail as evidence instead of passing as
generic agent activity.

When `--preflight` and `--proof-commands` are used together, proof commands are
printed only for agents that pass ACP initialize/session preflight. Agents that
resolve as shell commands but fail the ACP handshake print a withheld-command
notice instead, because a full evidence probe would fail before reaching the
story-specific file, terminal, or permission checks.

Use `--list-agents --preflight` when a command is only a probe candidate. The
preflight creates a short durable run and verifies ACP initialization plus
session creation, surfacing failures such as a generic shell command that starts
successfully but answers the ACP `initialize` request incorrectly.
Probe CLI output suppresses debug-level application logs by default so the
inventory, preflight, and report summaries remain readable as evidence. Add
`--verbose` when debugging the probe task itself and you need the current
logger level preserved. Inventory preflight also prints a final summary naming
how many static real-agent candidates passed, which keys are ready for full
evidence probes, and which keys failed preflight with their failure reason.

Use `--list-agents --registry --preflight --proof-commands` to fetch the public
ACP Registry and print npx-backed agent command suggestions. Each suggestion
lists its package and env key names, then prints a `HAVEN_AGENTS_JSON` command
that preflights one suggestion and prints its proof commands. Registry commands
download and run third-party code; use an approved workspace, approved auth
scope, and redactions before attempting a full evidence report.

Use `--save-registry-agent AGENT_ID` to persist one registry suggestion into
Haven's Agent Setup table. This only saves the command definition; run
`--list-agents --preflight` afterward before treating the saved command as ACP
evidence.

Before committing a report, inspect it for secrets in command arguments,
environment-derived output, prompts, and agent messages.

Use repeated `--redact value` flags for literal strings and repeated
`--redact-env ENV_VAR` flags for secrets stored in the environment. Redacted
reports include `redactions` metadata, but never the raw redaction values.

Use `--failure-report` alongside `--report` for mediated file and terminal
proof attempts. A passing run writes the positive report to `docs/probes`; a
failing run writes the failure report instead, so unsupported real-agent
capability boundaries do not accidentally become invalid positive artifacts.
Committed failure reports still must satisfy the stricter
`docs/probe-failures` validation contract.

Terminal probe output is summary-first by default. Use `--show-events` when you
need to inspect every persisted event payload in the terminal; committed
`--report` JSON files always include the full ordered event list.

Use `--require-real-agent` on any report intended to count as production-grade
Haven real-agent evidence. It rejects the built-in stub and the known local
test harness scripts used by automated coverage.

Use `--expect-min-agent-output-chars N` and
`--expect-min-agent-message-chunks N` when the story needs bounded long-output
evidence. Committed reports that declare these minimums must include
`agent_output_metrics` that meet them and an empty `missing_expected_output`
list.

Committed `*.json` reports in this directory, plus named negative boundary
reports in `docs/probe-failures/*.json` and aggregate load reports in
`docs/probe-load/*.json`, are validated by
`mix haven.probe_reports`, which also runs as part of `mix precommit`.

Use `--load-runs N` with `--require-real-agent` when the story needs repeated
real-agent runs through Haven's lifecycle:

```bash
mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "summarize this workspace" \
  --load-runs 2 \
  --load-concurrency 2 \
  --require-real-agent \
  --expect-event agent_initialized \
  --expect-event agent_session_started \
  --expect-event turn_finished \
  --report docs/probe-load/my-agent-basic-load.json
```

Load reports default to sequential repeated-run evidence. Use
`--load-concurrency N` to produce concurrent evidence; committed concurrent
reports must include overlapping child probe windows. Load reports do not prove
long-running external-agent output unless the prompt and expected events cover
that story.

## Committed Evidence

- `codex-acp-basic-current.json`: current positive real-agent basic probe from
  2026-07-01. It uses saved `codex-acp`
  (`npx @agentclientprotocol/codex-acp@1.0.1`) with `--require-real-agent` and
  proves initialization, session start, a prompted turn, streamed agent output,
  and `turn_finished` through Haven's durable run lifecycle.
- `codex-acp-basic.json`: earlier positive real-agent basic probe for the same
  adapter.
- `codex-acp-long-output.json`: positive bounded long-output real-agent probe
  for saved `codex-acp`. It requires at least 1,200 streamed output characters
  and at least 8 `agent_message_chunk` events; the committed report records
  1,632 characters across 305 chunks for durable run
  `95ab6336-8370-4422-9c4b-6997a011a18e`.
- `codex-acp-file-tool-call.json`: positive real-agent visibility evidence for
  file inspection through ACP `tool_call` / `tool_call_update`, not proof of
  Haven-mediated `fs/*` client request handling. The corresponding failed
  mediated read-capability probe is recorded in
  `docs/probe-failures/codex-acp-file-mediated-negative.json`; the corresponding
  mediated write-capability probe is recorded in
  `docs/probe-failures/codex-acp-file-write-mediated-negative.json`.
- `codex-acp-terminal-tool-call.json`: positive real-agent visibility evidence
  for terminal execution through ACP `tool_call` / `tool_call_update`, not proof
  of Haven-mediated `terminal/*` client request handling. The corresponding
  failed mediated-capability probe is recorded in
  `docs/probe-failures/codex-acp-terminal-mediated-negative.json`.
- `haven-capability-probe-basic.json`: positive local external-process ACP
  probe evidence for the basic turn lifecycle. This uses the committed
  `priv/acp_agents/haven_capability_probe_agent.exs` stdio agent, not the
  built-in stub and not a production coding agent.
- `haven-capability-probe-file-read.json`: positive local external-process ACP
  proof that a non-stub agent can request Haven-mediated
  `fs/read_text_file`, receive the response, and finish the turn.
- `haven-capability-probe-file-write-approval.json`: positive local
  external-process ACP proof that a non-stub agent can request Haven-mediated
  `fs/write_text_file`, pause on a permission decision, receive approval, write
  inside the workspace, and finish the turn.
- `haven-capability-probe-terminal-approval.json`: positive local
  external-process ACP proof that a non-stub agent can request Haven-mediated
  `terminal/create`, `terminal/wait_for_exit`, `terminal/output`, and
  `terminal/release` through an approval-gated terminal command.
- `haven-capability-probe-terminal-denied.json`: positive local
  external-process ACP proof that Haven denies a non-stub agent's
  `terminal/create` request under deny policy without spawning a terminal.
  Together these `haven-capability-probe-*` reports prove Haven's direct
  client-capability plumbing against a committed external stdio ACP process.
  They do not prove that a third-party production agent such as `codex-acp`
  exercises those direct `fs/*` or `terminal/*` client requests.
- `docs/probe-load/codex-acp-basic-load.json`: positive sequential multi-run
  real-agent evidence for the basic turn lifecycle through saved `codex-acp`.
- `docs/probe-load/codex-acp-basic-concurrent-load.json`: positive concurrent
  multi-run real-agent evidence for the basic turn lifecycle through saved
  `codex-acp`, with two overlapping child probe windows.
