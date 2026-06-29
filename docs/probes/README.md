# Agent Probe Evidence

This directory is for committed `mix haven.agent_probe --report` artifacts from
real, non-stub ACP agents.

The deterministic `stub-acp` agent proves the harness. A report only counts as
Grei/Haven real-agent evidence when all of the following are true:

- The `agent` field names a configured agent other than `stub-acp`.
- The report was produced through Haven's run lifecycle, not by talking directly
  to the agent process.
- `expected_events` names the lifecycle or capability events required by the
  story being validated.
- `missing_expected_events` is empty.
- `status` is `idle` or another explicitly expected terminal state for the
  story.
- The ordered `events` list shows the relevant ACP lifecycle, prompt, permission,
  file, terminal, failure, or recovery events.

Examples:

```bash
mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "summarize this workspace" \
  --expect-event agent_initialized \
  --expect-event agent_session_started \
  --expect-event turn_finished \
  --report docs/probes/my-agent-basic.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "read README.md" \
  --resolve-permissions allow \
  --expect-event permission_requested \
  --expect-event permission_resolved \
  --expect-event file_read_succeeded \
  --expect-event turn_finished \
  --report docs/probes/my-agent-file-read.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "run the test command" \
  --terminal-create-policy allow \
  --expect-event terminal_created \
  --expect-event terminal_output_succeeded \
  --expect-event terminal_released \
  --expect-event turn_finished \
  --report docs/probes/my-agent-terminal.json

mix haven.agent_probe \
  --agent my-agent \
  --workspace /path/to/repo \
  --prompt "try to open a terminal" \
  --terminal-create-policy deny \
  --expect-event terminal_create_requested \
  --expect-event capability_policy_applied \
  --expect-event terminal_create_denied \
  --expect-event turn_finished \
  --report docs/probes/my-agent-terminal-denied.json
```

Before committing a report, inspect it for secrets in command arguments,
environment-derived output, prompts, and agent messages.
