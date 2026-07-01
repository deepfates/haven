# Agent Probe Load Evidence

This directory contains committed `mix haven.agent_probe --load-runs N --report`
artifacts from real, non-stub ACP agents.

Load reports are aggregate reports. Each child report must satisfy the normal
real-agent evidence rules from `docs/probes/README.md`, and the aggregate must
show:

- `kind: "agent_probe_load"`.
- `agent` names a configured agent other than `stub-acp`.
- `run_count` is at least 2.
- `status` is `passed`.
- `reports` contains exactly `run_count` child reports.
- Every child report was generated with `--require-real-agent`.
- Every child report has a distinct durable Haven `run_id`.
- Every child report agrees with the aggregate `agent`, `workspace`, and
  `prompt`.
- `expected_events` names the lifecycle or capability events required by the
  story being validated.

Current load probes run sequentially. They prove repeated durable real-agent
runs through Haven's lifecycle, not concurrent scheduling, long-running output,
or production load behavior.

Before committing a load report, inspect it for secrets in prompts, command
arguments, environment-derived output, and agent messages. Reports can include
text the agent read from the workspace.

`mix haven.probe_reports` validates committed load reports alongside
`docs/probes/*.json` and `docs/probe-failures/*.json`.

## Committed Evidence

- `codex-acp-basic-load.json`: current positive real-agent sequential load
  probe from 2026-07-01. It uses saved `codex-acp`
  (`npx @agentclientprotocol/codex-acp@1.0.1`) with `--require-real-agent`,
  creates two distinct durable Haven runs, and proves initialization, session
  start, a prompted turn, and `turn_finished` in each child run.
