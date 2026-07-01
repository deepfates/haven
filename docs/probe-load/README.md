# Agent Probe Load Evidence

This directory contains committed `mix haven.agent_probe --load-runs N --report`
artifacts from real, non-stub ACP agents.

Load reports are aggregate reports. Each child report must satisfy the normal
real-agent evidence rules from `docs/probes/README.md`, and the aggregate must
show:

- `kind: "agent_probe_load"`.
- `agent` names a configured agent other than `stub-acp`.
- `run_count` is at least 2.
- `concurrency`, when present, is between 1 and `run_count`.
- `status` is `passed`.
- `failures` is present as an empty list.
- `reports` contains exactly `run_count` child reports.
- Concurrent reports with `concurrency > 1` include `child_windows` whose
  timestamps show at least two overlapping child probe windows.
- Every child report was generated with `--require-real-agent`.
- Every child report has a distinct durable Haven `run_id`.
- Every child report agrees with the aggregate `agent`, `workspace`, and
  `prompt`.
- Every child report agrees with the aggregate acceptance contract:
  `expected_events`, `expected_event_fields`, and `expected_output`.
- `expected_events` names the lifecycle or capability events required by the
  story being validated.

Load probes default to sequential execution. Passing `--load-concurrency N`
runs up to N child probes at the same time. Concurrent reports prove only the
specific overlap and story in the committed artifact; they do not prove
long-running output behavior, larger fan-out, or production traffic patterns.

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
- `codex-acp-basic-concurrent-load.json`: current positive real-agent
  concurrent load probe from 2026-07-01. It uses saved `codex-acp` with
  `--require-real-agent`, creates two distinct durable Haven runs at
  `concurrency: 2`, and records overlapping child probe windows from
  `2026-07-01T09:24:13.791789Z` to `2026-07-01T09:24:22.091270Z`.
