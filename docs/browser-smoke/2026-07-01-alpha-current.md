# Browser Smoke: Current Alpha Candidate

Date: 2026-07-01

Verified application commit: `cbbfaa8d`

Purpose: rerun the browser sanity gate after the mobile-first inbox/run
simplification pass, current real-agent probe refresh, load/probe output
readability improvements, and unsupported capability gap surfacing, using the
current dev server at `http://127.0.0.1:4000/`.

## CLI Preconditions

- `MIX_ENV=dev mix haven.pending_migrations`
  - Result: `No pending migrations.`
- `mix precommit`
  - Result: passed with 262 tests, 0 failures.
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000
  --load-runs 3 --timeout-ms 30000`
  - Result: passed.
  - Runtime smoke run id: `faac147e-cf60-434f-b3a8-63b77a28d4a9`
  - Runtime smoke run URL:
    `http://127.0.0.1:4000/runs/faac147e-cf60-434f-b3a8-63b77a28d4a9`
  - Additional load smoke created 3 disposable runs and verified page isolation.
- `mix haven.agent_probe --agent codex-acp --workspace
  /Users/deepfates/Hacking/github/deepfates/haven --prompt "Summarize this
  workspace in one short sentence." --require-real-agent --expect-event
  agent_initialized --expect-event agent_session_started --expect-event
  turn_finished --report docs/probes/codex-acp-basic-current.json`
  - Result: passed.
  - Probe run id: `2b8270f7-0707-4013-bd6e-18de0a08b5fd`

## Browser Checks

Target pages:

- `http://127.0.0.1:4000/`
- Opened run from inbox:
  `http://127.0.0.1:4000/runs/a2a7370a-c97f-4247-95f1-58f1e0145226`

Viewports:

- Current/default in-app browser viewport.
- Mobile override: `390x844`.

Inbox checks:

- `#haven-inbox` rendered.
- `h1` text is `Inbox`.
- `#inbox-queue-summary` present.
- `#inbox-run-filters` present as the compact `Find runs` disclosure.
- `#inbox-search-form` remains available inside that disclosure.
- `#new-run-panel` present as a secondary disclosure.
- Run rows appear in the mobile first viewport before expanded filter controls.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default or `390x844`.
- Current `390x844` inspection measured `clientWidth=390` and
  `scrollWidth=390`.
- Current `390x844` first primary element ids began with
  `inbox-attention-summary`, `inbox-queue-summary`, then `new-run-panel`,
  preserving the attention/queue before setup hierarchy.
- Product-visible proof metadata is absent from the primary header path.

Run detail checks:

- `#run-thread` present.
- `#run-nav-thread`, `#run-nav-decisions`, `#run-nav-message`, and
  `#run-nav-evidence` present.
- `#run-conversation` or `#run-turn-summary` present.
- `#pending-permission-card` or `#run-permission-audit` present.
- `#run-security-boundary` present.
- On a disconnected waiting run, `#run-control-panel` remains available but no
  longer has the mobile `sticky` class while prompting is disabled.
- A waiting permission card presents prompt context, consequence, and action
  buttons first; policy chips, request ids, option summaries, and raw input are
  available inside the closed `#pending-permission-details` / `Review details`
  disclosure.
- Run facts/details are available without dominating the primary header.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default or `390x844`.
- Current `390x844` inspection measured `clientWidth=390` and
  `scrollWidth=390`.
- Current `390x844` first primary element ids included `run-section-nav`,
  `run-thread`, and `pending-permission-card` before evidence/detail sections;
  `#pending-permission-details` remained closed by default.
- Product-visible proof metadata is absent from the primary header path.

This smoke record verifies the internal-alpha browser sanity gate at verified
application commit `cbbfaa8d`. It does not change the production-grade boundary:
real-agent Haven-mediated file and terminal capability proof remains unproven
except for the explicit negative capability-gap artifacts named in the probe
documentation.
