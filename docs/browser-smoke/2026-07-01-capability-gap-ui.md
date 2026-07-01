# Browser Smoke: Capability Gap Evidence UI

Date: 2026-07-01

Purpose: verify that real-agent negative capability evidence is visible in the
product UI instead of living only in documentation.

## Checks

Inbox at `http://127.0.0.1:4000/`:

- `codex-acp` run rows render `4 accepted probes`.
- The same rows render `2 capability gaps`.
- The capability-gap reason reads: `real-agent probes observed generic ACP tool
  calls, not Haven-mediated file/terminal handling`.
- Default and `390x844` mobile viewport checks had no horizontal overflow.
- No pending migration page, server error page, or browser console
  error/warning entries appeared.

Run detail at
`http://127.0.0.1:4000/runs/e77fa898-d57c-40d5-a9e1-355f72c221bd`:

- Run title rendered as `Agent probe: codex-acp`.
- Run facts render `4 accepted probes`.
- Run facts render `2 capability gaps`.
- Capability gap details list:
  - `docs/probe-failures/codex-acp-file-mediated-negative.json`
  - `docs/probe-failures/codex-acp-terminal-mediated-negative.json`
- The `390x844` mobile viewport had no horizontal overflow.
- No pending migration page, server error page, or browser console
  error/warning entries appeared.

This smoke verifies the product surface now distinguishes accepted real-agent
evidence from known real-agent mediated-capability gaps.
