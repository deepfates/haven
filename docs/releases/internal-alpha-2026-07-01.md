# Haven Internal Alpha Notes

Date: 2026-07-01

Branch: `codex/elixir-cutover`

Status: alpha candidate. This is suitable for trusted local use against
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

## Current Positive Evidence

- `mix precommit` passed with 230 tests and 4 validated probe reports.
- `MIX_ENV=dev mix haven.pending_migrations` reported no pending migrations.
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000`
  passed and produced run
  `be122feb-0840-47ef-9307-c0b463559b0b`.
- `docs/browser-smoke/2026-07-01-alpha-cut.md` records the latest in-app
  browser checks for desktop/default and `390x844` mobile viewport sizes.
- `docs/probes/codex-acp-basic-current.json` is a current positive real-agent
  report for saved `codex-acp`
  (`npx @agentclientprotocol/codex-acp@1.0.1`). It passed
  `--require-real-agent` and verified `agent_initialized`,
  `agent_session_started`, and `turn_finished` for durable run
  `e77fa898-d57c-40d5-a9e1-355f72c221bd`.

## What Is Not Production-Grade

- Haven-mediated `fs/*` file capability requests are not yet proven against a
  real non-test ACP agent.
- Haven-mediated `terminal/*` capability requests are not yet proven against a
  real non-test ACP agent.
- Current `codex-acp` file and terminal evidence shows useful visibility
  through ACP `tool_call` / `tool_call_update`, not direct client request
  mediation.
- Long-running output behavior has not been proven under realistic volume.
- Many simultaneous external-agent runs across multiple folders have not been
  load-tested.
- Credential/auth scope is visible enough for local alpha, but not yet a full
  product security policy.
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

- Verified application commit: `03657003`
- `MIX_ENV=dev mix haven.pending_migrations`: passed with no pending
  migrations.
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000`:
  passed with run id `e1d746a8-12f2-44f2-ac66-aa8e8686f0b5`.
- Browser sanity: default and `390x844` mobile checks passed; see
  `docs/browser-smoke/2026-07-01-alpha-current.md`.
- `mix precommit`: passed at verified application commit `03657003` with 230
  tests and 4 validated probe reports.

Current basic real-agent probe shape:

```bash
mix haven.agent_probe \
  --agent codex-acp \
  --workspace /path/to/approved/workspace \
  --prompt "Reply exactly: Haven ACP current real-agent smoke" \
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

This alpha should be cut when the release operator reruns the required gates in
`docs/internal-alpha-checklist.md` and records the exact branch, commit, date,
and operator. After that, stop local hardening unless a probe, runtime smoke, or
named user story fails.
