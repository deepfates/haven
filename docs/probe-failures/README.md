# Agent Probe Failure Evidence

This directory holds named failed `mix haven.agent_probe --report` artifacts.
They are not positive production evidence, but they are still validated by
`mix haven.probe_reports` as real-agent boundary evidence.

Use these reports to preserve explicit product boundaries: an agent may do
useful real work through ACP while still failing to exercise a Haven-mediated
client capability story.

Failure reports count as useful boundary evidence only when they include
`real_agent_evidence.required=true`, `real_agent_evidence.accepted=true`, a
non-empty `missing_expected_events` list with at least one client capability
event, at least one matching field-level capability expectation, and a
`tool_call_only_capability_gap` diagnostic backed by actual `tool_call` /
`tool_call_update` events. They must also include
`unsupported_client_capabilities`, which turns the observed boundary into a
machine-readable declaration of the mediated capability family that the agent
class did not exercise. Unlike positive reports, failure reports may have
`status=failed` when the failed run state is itself the honest boundary being
recorded.

## Current Failure Reports

- `codex-acp-file-mediated-negative.json`: regenerated on 2026-07-01 against
  saved `codex-acp` (`npx @agentclientprotocol/codex-acp@1.0.1`). The probe
  used explicit allow policy for `README.md` and `docs`, then required
  `capability_policy_applied`, `file_read_requested`, and
  `file_read_succeeded`. The agent read `README.md` and returned useful output,
  but only via ACP `tool_call` / `tool_call_update`; the report records
  `tool_call_only_capability_gap`, declares `fs/read_text_file` unsupported for
  Haven-mediated proof with this agent class, and includes accepted real-agent
  metadata.
- `codex-acp-file-write-mediated-negative.json`: generated on 2026-07-01
  against saved `codex-acp`. The probe required `permission_requested`,
  `permission_resolved`, `file_write_requested`, and `file_write_succeeded`.
  The agent wrote `notes/haven-probe.txt`, but did so through ACP `tool_call` /
  `tool_call_update` rather than Haven's direct `fs/write_text_file` client
  handler. The report records `tool_call_only_capability_gap`, declares
  `fs/write_text_file` unsupported for Haven-mediated proof with this agent
  class, and includes accepted real-agent metadata.
- `codex-acp-terminal-mediated-negative.json`: regenerated on 2026-07-01
  against saved `codex-acp`. The probe required `permission_requested`,
  `permission_resolved`, `terminal_create_requested`, `terminal_created`, and
  `terminal_output_requested`. The agent ran the sentinel command and returned
  the answer, but only via ACP `tool_call` / `tool_call_update`; the report
  records `tool_call_only_capability_gap`, declares the mediated `terminal`
  capability family unsupported for this agent class, and includes accepted
  real-agent metadata.

These reports mean Haven currently has real-agent visibility for Codex file read,
file write, and terminal work, but not proof that Codex exercises Haven's direct
`fs/*` or `terminal/*` client request handlers.
