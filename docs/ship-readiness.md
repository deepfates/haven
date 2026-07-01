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
is not another local UI polish pass. Haven now has local external-process proof
for its direct file and terminal client-capability handlers, but the main
remaining proof is third-party production ACP agent evidence through those same
important stories.

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

Status: cut for trusted local use on 2026-07-01.

Internal alpha means a trusted developer can use Haven against configured
agents with known limitations and inspect failures honestly.

Use `docs/internal-alpha-checklist.md` as the release checklist. The current
alpha cut is documented in `docs/releases/internal-alpha-2026-07-01.md`. Stop
adding local hardening until a probe, runtime smoke, or user story fails.

Required before calling alpha:

- Run `mix precommit` cleanly.
- Run `MIX_ENV=dev mix haven.pending_migrations` against the dev database.
- Run `MIX_ENV=dev mix haven.runtime_smoke` against `http://127.0.0.1:4000/`.
- Produce or update at least one current positive real-agent basic probe report.
- Document negative evidence for any real-agent file or terminal capability
  story that remains unproven.
- Write release notes that name the non-production boundaries plainly.

Non-blocking for alpha:

- OS-native folder picker.
- Authenticated multi-user identity.
- Full interactive terminal UX.
- ACP-native session resume/fork/list.
- Complete protocol payload schemas.
- Product-grade visual polish.

Minimum alpha UX still must hold: no product-visible developer harnesses, no
dashboard-like proof walls in the primary path, no mobile overflow in the inbox
or run thread, and one obvious primary action on each core screen.

### Production Grade

Status: no.

Production grade requires evidence that Haven works with real external ACP
agents, not only the stub, configured fake harness, and local capability probe.

Production blockers:

- At least one real non-test ACP agent must pass committed probe reports for
  each production-critical story, not only the basic turn story.
- Haven-mediated file read/write capability requests are now proven against a
  committed local external ACP probe process, but must still be proven against a
  third-party production agent or explicitly declared unsupported for that agent
  class.
- Haven-mediated terminal capability requests are now proven against a
  committed local external ACP probe process for create/wait/output/release and
  denial, but must still be proven against a third-party production agent or
  explicitly declared unsupported for that agent class.
- Longer-duration output and larger-fan-out multi-run behavior need evidence
  under realistic external-agent load. Bounded long-output and three-run
  concurrent real-agent basic evidence now exist for `codex-acp`, but they do
  not prove arbitrary duration or production-scale fan-out.
- Auth/auth-scope handling must be explicit enough that a user can understand
  which credentials are being used and where.
- Security boundaries around workspace access must remain visible to users and
  grounded in the product policy in `docs/workspace-access-policy.md`, not only
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

1. For production-grade work, target third-party production-agent
   file/terminal mediation proof or a named negative report for unsupported
   agent classes.
2. Add longer-duration or larger-fan-out external-agent evidence only when it
   uses a real configured ACP agent, not the local stub alone.
3. Tighten auth/credential proof only when an agent actually requires
   interactive authentication or scoped credentials.

## Completion Claim

The active production-grade telos should not be marked complete yet.

The honest current claim is:

Haven has an internal-alpha cut with current browser smoke, runtime smoke,
tests, positive basic real-agent evidence, and local external-process proof for
Haven-mediated file and terminal callbacks. Production-grade status remains
unproven until third-party production ACP agents pass or explicitly fail the
critical file, terminal, decision, persistence, and inspection stories.
