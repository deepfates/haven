# Haven Ship Readiness

This document defines a practical stop rule for the current Elixir Haven work.
It exists to prevent the production-grade telos from turning into endless local
hardening.

## Current Verdict

Haven is past the "vibe spike" stage. It is a real Phoenix/OTP ACP client with
durable runs, explicit permission decisions, an operational inbox, run detail
threads, restart/reconnect paths, file and terminal capability handling through
the local ACP harness, retained history, probe artifacts, and a serious
validation matrix.

Haven is not yet production-grade in the literal sense. The main missing proof
is not another local UI polish pass. The main missing proof is real non-test ACP
agent evidence through the important stories, especially Haven-mediated file
and terminal client capabilities.

## Stop Rule

Do not keep adding local hardening slices merely because they are valid
improvements. Add new local work only when it directly supports one of these:

- A real-agent probe can be run, interpreted, or trusted more clearly.
- A user running many agents across folders can avoid a concrete confusion or
  data-loss risk.
- A browser/runtime smoke can falsify a claim that currently has only unit or
  LiveView evidence.
- A known production blocker becomes smaller, more explicit, or testable.

Everything else should be treated as backlog until the real-agent proof gap is
closed.

## Shippable Lines

### Spike Complete

Status: yes.

The spike is complete if the question is whether Elixir/Phoenix/OTP can host
the product shape:

- Durable run records and event logs exist.
- ACP stdio plumbing exists through `agent_client_protocol`.
- Run processes own agent lifecycle.
- Permission requests become explicit decisions.
- The app can start runs outside an IDE.
- The UI is conversation/inbox-centered rather than purely dashboard-centered.
- Tests and browser smoke exercise the core local harness flows.

### Internal Alpha

Status: close, but needs an explicit release cut.

Internal alpha means a trusted developer can use Haven against configured
agents with known limitations and inspect failures honestly.

Required before calling alpha:

- Run `mix precommit` cleanly.
- Run `MIX_ENV=dev mix haven.pending_migrations` against the dev database.
- Run `MIX_ENV=dev mix haven.runtime_smoke` against `http://127.0.0.1:4000/`.
- Produce or update at least one current agent probe report, even if it is a
  negative report that documents a capability gap.
- Write release notes that name the non-production boundaries plainly.

Non-blocking for alpha:

- OS-native folder picker.
- Authenticated multi-user identity.
- Full interactive terminal UX.
- ACP-native session resume/fork/list.
- Complete protocol payload schemas.
- Product-grade visual polish.

### Production Grade

Status: no.

Production grade requires evidence that Haven works with real external ACP
agents, not only the stub and configured fake harness.

Production blockers:

- At least one real non-test ACP agent must pass a committed probe report.
- Haven-mediated file read/write capability requests must be proven against a
  real non-test agent or explicitly declared unsupported for that agent class.
- Haven-mediated terminal capability requests must be proven against a real
  non-test agent or explicitly declared unsupported for that agent class.
- Long-running output and multi-run behavior need evidence under realistic
  load, not only small local examples.
- Auth/auth-scope handling must be explicit enough that a user can understand
  which credentials are being used and where.
- Security boundaries around workspace access need a product policy, not only
  implementation helpers and path checks.

## What Is Worth Porting

If Haven were rewritten or ported, the worthwhile product/code ideas are:

- The durable run/event model.
- The run process as the owner of ACP connection lifecycle.
- Permission decisions as first-class app records, not transient modals.
- The inbox lanes: Needs You, Running, History, Archived.
- The run detail hierarchy: Thread, Decisions, Message, Evidence.
- Evidence-first validation: probe reports, browser smoke, negative cases.
- Workspace-scoped file and terminal capability mediation.
- Honest distinction between launch readiness, ACP proof, and real-agent proof.

Less worth porting directly:

- Incidental Tailwind class details.
- Stub-agent-specific affordances except as test harness ideas.
- Any UI shape that behaves like an admin dashboard instead of a work inbox.
- Local hardening that does not support real-agent evidence or user trust.

## Next Best Work

The next best work is not another broad polish pass. It is one of:

1. Run a real configured ACP agent through `mix haven.agent_probe --report` and
   commit the report if it passes.
2. If the real agent fails, commit a negative evidence note/report that names
   the exact gap.
3. Cut an internal-alpha checklist from this document and stop adding features
   until the checklist is green.

## Completion Claim

The active production-grade telos should not be marked complete yet.

The honest current claim is:

Haven has a strong internal-alpha foundation and a credible path to production,
but production-grade status remains unproven until real non-test ACP agents pass
the critical file, terminal, decision, persistence, and inspection stories.
