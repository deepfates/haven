# Agent Probe Evidence

This directory is for committed `mix haven.agent_probe --report` artifacts from
real, non-stub ACP agents.

The deterministic `stub-acp` agent proves the harness. A report only counts as
Grei/Haven real-agent evidence when all of the following are true:

- The `agent` field names a configured agent other than `stub-acp`.
- The report was generated with `--require-real-agent`, so `real_agent_evidence`
  is present with `accepted: true`.
- The report was produced through Haven's run lifecycle, not by talking directly
  to the agent process.
- `expected_events` names the lifecycle or capability events required by the
  story being validated.
- `missing_expected_events` is empty.
- `expected_event_fields`, when present, names payload facts required by the
  story being validated, such as requested paths, terminal commands, exit
  statuses, and permission decisions.
- `missing_expected_event_fields` is empty.
- Reports that claim Haven-mediated `file_*` or `terminal_*` capability events
  in `expected_events` must include matching `expected_event_fields` entries
  for those event types; type-only capability evidence is not accepted.
- `status` is `idle` or another explicitly expected terminal state for the
  story.
- The ordered `events` list shows the relevant ACP lifecycle, prompt, permission,
  file, terminal, failure, or recovery events.

Some agents expose file and terminal activity as ACP `tool_call` /
`tool_call_update` session updates instead of calling the client request
methods that Haven mediates directly. Those reports are useful real-agent
evidence for visibility and timeline projection, but they must not be counted as
proof of Haven-mediated `fs/*` or `terminal/*` permission handling unless the
expected events include the corresponding `file_*`, `terminal_*`, and
permission events.

Examples:

```bash
mix haven.agent_probe --list-agents --workspace /path/to/repo
mix haven.agent_probe --list-agents --preflight --workspace /path/to/repo
mix haven.agent_probe --list-agents --registry --workspace /path/to/repo

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
  --report docs/probes/my-agent-file-read.json

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
  --report docs/probes/my-agent-terminal-approval.json

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
  --report docs/probes/my-agent-terminal.json

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
  --report docs/probes/my-agent-terminal-denied.json
```

Use `--list-agents` first when preparing real-agent evidence. It prints every
configured agent, whether its command resolves on this machine, whether it can
count as a `--require-real-agent` candidate, and an example basic probe command.
The inventory shows environment variable names but not their values.

Use `--list-agents --preflight` when a command is only a probe candidate. The
preflight creates a short durable run and verifies ACP initialization plus
session creation, surfacing failures such as a generic shell command that starts
successfully but answers the ACP `initialize` request incorrectly.

Use `--list-agents --registry` to fetch the public ACP Registry and print
npx-backed agent command suggestions, including the `HAVEN_AGENTS_JSON` shape
needed to try each suggestion through Haven's preflight path. Registry commands
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

Use `--require-real-agent` on any report intended to count as Grei/Haven
real-agent evidence. It rejects the built-in stub and the known local test
harness scripts used by automated coverage.

Committed `*.json` reports in this directory are validated by
`mix haven.probe_reports`, which also runs as part of `mix precommit`.
