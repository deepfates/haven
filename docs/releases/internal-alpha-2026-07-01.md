# Haven Internal Alpha Notes

Date: 2026-07-01

Branch: `codex/elixir-cutover`

Status: internal alpha cut. This is suitable for trusted local use against
configured agents with known limitations. It is not a production-grade claim.

## What Works Now

- Haven runs as a Phoenix/LiveView app outside an IDE.
- Runs are durable records with ordered event timelines.
- External ACP agents can be launched through the saved agent configuration
  path.
- The inbox is organized around work lanes: Needs You, Running, History, and
  Archived.
- Run detail is organized around a thread-first experience, with decisions,
  message controls, and evidence/details available on demand.
- Permission requests become explicit decision cards and durable audit records.
- Local harness coverage exercises file read/write and terminal capability
  mediation.
- Runtime smoke exercises the dev server path, not only unit tests.
- Browser smoke checks the simplified mobile-first hierarchy and page overflow.
- Workspace access policy is visible before launch and on run detail, including
  the workspace-root boundary, blank-scope semantics, and terminal cwd rule.

## Current Positive Evidence

- Latest maintenance verification: `mix precommit` passed at commit
  `8d65a165` with 254 tests, 5 validated positive probe reports, 2 validated
  negative probe reports, and 2 validated real-agent load reports.
- `MIX_ENV=dev mix haven.pending_migrations` reported no pending migrations.
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000`
  passed and produced run
  `3223240c-67e0-49dc-abf1-3be3e53bf353`.
- `docs/browser-smoke/2026-07-01-alpha-current.md` records the latest in-app
  browser checks for desktop/default and `390x844` mobile viewport sizes at
  application commit `02496359`. Later commits through `8d65a165` changed docs
  and probe CLI output, not the rendered inbox/run UI checked there.
- `docs/probes/codex-acp-basic-current.json` is a current positive real-agent
  report for saved `codex-acp`
  (`npx @agentclientprotocol/codex-acp@1.0.1`). It passed
  `--require-real-agent` and verified `agent_initialized`,
  `agent_session_started`, and `turn_finished` for durable run
  `2b8270f7-0707-4013-bd6e-18de0a08b5fd`.

## What Is Not Production-Grade

- Haven-mediated `fs/*` file capability requests are not yet proven against a
  real non-test ACP agent.
- Haven-mediated `terminal/*` capability requests are not yet proven against a
  real non-test ACP agent.
- Current `codex-acp` file and terminal evidence shows useful visibility
  through ACP `tool_call` / `tool_call_update`, not direct client request
  mediation.
- Bounded long-output behavior has one current positive `codex-acp` report, but
  arbitrary long duration and production-scale output volume remain unproven.
- Two-run sequential and concurrent real-agent load evidence exists for
  `codex-acp`, but many simultaneous external-agent runs across multiple
  folders remain unproven.
- Credential/auth scope is visible enough for local alpha, but interactive auth
  flows for agents that require credentials are not proven.
- Packaging, upgrades, backups, and multi-user identity are out of scope for
  this alpha.

## Validation Commands

```bash
mix precommit
MIX_ENV=dev mix haven.pending_migrations
MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000
mix haven.probe_reports
mix haven.agent_probe --list-agents --workspace /Users/deepfates/Hacking/github/deepfates/haven
```

Latest application-candidate verification:

- Latest maintenance verification commit: `8d65a165`
- `MIX_ENV=dev mix haven.pending_migrations`: passed with no pending
  migrations.
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000`:
  passed with run id `3223240c-67e0-49dc-abf1-3be3e53bf353`.
- Browser sanity: default and `390x844` mobile checks passed; see
  `docs/browser-smoke/2026-07-01-alpha-current.md`.
- `mix precommit`: passed at maintenance commit `8d65a165` with 254 tests.
- `mix haven.probe_reports`: passed at maintenance commit `8d65a165` with 5
  positive probe reports, 2 failure reports, and 2 load reports.

Current basic real-agent probe shape:

```bash
mix haven.agent_probe \
  --agent codex-acp \
  --workspace /Users/deepfates/Hacking/github/deepfates/haven \
  --prompt "Summarize this workspace in one short sentence." \
  --require-real-agent \
  --expect-event agent_initialized \
  --expect-event agent_session_started \
  --expect-event turn_finished \
  --report docs/probes/codex-acp-basic-current.json
```

Current negative mediated-capability evidence:

- `docs/probe-failures/codex-acp-file-mediated-negative.json`
- `docs/probe-failures/codex-acp-terminal-mediated-negative.json`

Both reports show useful real `codex-acp` work through ACP `tool_call` /
`tool_call_update`, but missing Haven-mediated permission, file, and terminal
client-handler events. Treat these as production boundaries, not positive
capability proof.

## Alpha Cut Line

This alpha is cut for trusted local use at verified application commit
`26de37b1`, with later maintenance verification through `8d65a165`. After this
point, stop local hardening unless a real-agent probe, runtime smoke, or named
user story fails.
