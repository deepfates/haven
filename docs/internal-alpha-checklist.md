# Haven Internal Alpha Checklist

This checklist is the release cut for an internal alpha. It turns
`docs/ship-readiness.md` into a concrete stop rule.

Internal alpha means Haven is usable by a trusted developer against configured
agents with known limitations. It does not mean production-grade.

## Release Cut

- Branch: `codex/elixir-cutover`
- Verified application commit: `26de37b1`
- Date: 2026-07-01
- Operator: Codex
- Last maintenance verification commit: `8d65a165`

## Required Gates

All gates must pass before calling a build "internal alpha".

### 1. Repo Gate

Command:

```bash
mix precommit
```

Pass condition:

- Probe report validation passes.
- Compile warnings-as-errors pass.
- The full test suite passes.

Evidence:

- Original alpha result: passed at verified application commit `26de37b1` with
  238 tests, 4 validated positive probe reports, and 2 validated negative probe
  reports.
- Latest maintenance result: `mix precommit` passed at commit `8d65a165` with
  254 tests; `mix haven.probe_reports` validated 5 positive probe reports, 2
  failure reports, and 2 load reports.

### 2. Dev Database Gate

Command:

```bash
MIX_ENV=dev mix haven.pending_migrations
```

Pass condition:

- The dev database used by `http://127.0.0.1:4000/` has no pending migrations.

Evidence:

- Result: `No pending migrations.`
- Notes: latest maintenance verification passed at application commit
  `8d65a165`.

### 3. Runtime Smoke Gate

Command:

```bash
mix phx.server
MIX_ENV=dev mix haven.runtime_smoke
```

Pass condition:

- The smoke creates a disposable run through the dev-server path.
- The smoke exercises permission approval, ACP file read/write approval,
  deterministic terminal execution, and rendered thread/decision/evidence
  surfaces.
- The smoke exits successfully.

Evidence:

- Result: passed against `http://127.0.0.1:4000`.
- Notes: alpha recorded run
  `3223240c-67e0-49dc-abf1-3be3e53bf353` at application commit `26de37b1`.

### 4. Browser Sanity Gate

Manual browser check against `http://127.0.0.1:4000/`:

- Inbox loads without pending migration or server errors.
- A run can be opened from the inbox.
- Run detail shows the Thread / Decisions / Message / Evidence navigation.
- A waiting decision is visible as a decision card, not buried in raw timeline
  JSON.
- A narrow mobile viewport has no horizontal page overflow on inbox or run
  detail.

Evidence:

- Result: default and `390x844` mobile checks passed for application commit
  `02496359`, including later mobile-first inbox/run simplification checks.
- Notes: see `docs/browser-smoke/2026-07-01-alpha-current.md`; earlier
  responsive evidence is in `docs/browser-smoke/2026-07-01-alpha-cut.md` and
  `docs/browser-smoke/2026-07-01-runtime-and-responsive.md`.

### 5. Agent Probe Evidence Gate

Run at least one current real-agent happy-path probe and commit or document the
result. Negative probes still matter, but they explain known limits; they do not
substitute for proving that Haven can start a real agent and complete a basic
turn.

Preferred positive evidence:

```bash
mix haven.agent_probe \
  --agent AGENT_KEY \
  --workspace /path/to/approved/workspace \
  --prompt "summarize this workspace" \
  --require-real-agent \
  --expect-event agent_initialized \
  --expect-event agent_session_started \
  --expect-event turn_finished \
  --report docs/probes/AGENT_KEY-basic.json
```

Required internal-alpha negative evidence for any claimed capability gap:

- A failed real-agent probe report or note that names the exact failure.
- A `tool_call_only_capability_gap` finding that explains which story did not
  exercise Haven-mediated file or terminal handlers.
- A preflight failure that identifies command, cwd, auth, or protocol mismatch.

Pass condition:

- There is at least one current positive real-agent basic probe artifact.
- Any committed positive real-agent report passes `mix haven.probe_reports`.
- Any missing mediated file or terminal story has a named negative probe report
  or note; committed negative reports must also pass `mix haven.probe_reports`.
- Secrets are redacted with `--redact` or `--redact-env`.

Evidence:

- Result: current positive real-agent basic probe passed and validates.
- Artifact path: `docs/probes/codex-acp-basic-current.json`
- Additional positive evidence: bounded long-output real-agent probe
  `docs/probes/codex-acp-long-output.json`, plus sequential and concurrent
  two-run real-agent load reports in `docs/probe-load/`.
- Negative artifact paths:
  `docs/probe-failures/codex-acp-file-mediated-negative.json` and
  `docs/probe-failures/codex-acp-terminal-mediated-negative.json`
- Notes: `codex-acp` file and terminal stories remain visibility evidence via
  ACP `tool_call` / `tool_call_update`, not proof of Haven-mediated `fs/*` or
  `terminal/*` client request handling.

### 6. Release Notes Gate

Create release notes for the alpha cut.

Required content:

- What Haven can do now.
- What is explicitly not production-grade.
- Which agent(s) were probed.
- Which capability stories were proven.
- Which capability stories failed or remain unproven.
- How to run the same validation commands.

Evidence:

- Result: release notes complete for the current alpha cut.
- Release notes path: `docs/releases/internal-alpha-2026-07-01.md`
- Notes:

## Alpha Non-Goals

Do not block internal alpha on these unless they are needed for the selected
agent evidence:

- OS-native folder picker.
- Authenticated multi-user identity.
- Full interactive terminal UX.
- ACP-native session resume/fork/list.
- Complete protocol payload schemas.
- Visual redesign beyond the conversation/inbox hierarchy already established.

## Production Blockers After Alpha

These remain blockers for the full production-grade claim:

- Real non-test ACP agent evidence for file read/write capability mediation.
- Real non-test ACP agent evidence for terminal capability mediation.
- Long-running output behavior under realistic volume.
- Multi-run behavior under realistic external-agent load.
- Real-agent proof that credential/auth flows work end-to-end when an agent
  requires interactive authentication.

## Stop Rule

All required gates are green for this alpha cut. Stop adding local hardening
until a real-agent probe, runtime smoke, or user story fails.

If any required gate fails, the next task is to fix or document that gate. Do
not substitute an unrelated improvement.
