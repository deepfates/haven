# Browser Smoke: Current Alpha Candidate

Date: 2026-07-01

Verified application commit: `7e91983a`

Purpose: rerun the browser sanity gate against the current dev server at
`http://127.0.0.1:4000/` after refreshing runtime smoke/load evidence and
real-agent probe/capability evidence. The smoke intentionally checks for the
actual failure modes seen during development: pending dev migrations, server
error pages, horizontal overflow, hidden decision state, and proof metadata
dominating the product surface.

## CLI Preconditions

- `MIX_ENV=dev mix haven.pending_migrations`
  - Result: `No pending migrations.`
- `mix precommit`
  - Result: passed with 275 tests, 0 failures.
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000
  --load-runs 3 --timeout-ms 30000`
  - Result: passed.
  - Runtime smoke run id: `7fb44008-7b0d-49be-a888-d6a283f720ed`
  - Runtime smoke run URL:
    `http://127.0.0.1:4000/runs/7fb44008-7b0d-49be-a888-d6a283f720ed`
  - Additional load smoke created 3 disposable runs and verified page isolation.
- `mix haven.probe_reports`
  - Result: latest committed probe corpus validates 5 positive reports, 3
    failure reports, and 2 load reports.

## Browser Checks

Target pages:

- `http://127.0.0.1:4000/`
- Current runtime smoke run:
  `http://127.0.0.1:4000/runs/7fb44008-7b0d-49be-a888-d6a283f720ed`
- Deterministic waiting-decision run created with `POST /dev/runs`, then
  `POST /dev/runs/:id/sample/permission`:
  `http://127.0.0.1:4000/runs/ee6ef6bf-1c4b-446e-9cf0-0c1c21e83fa7`

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
- No horizontal overflow at default/current browser width or `390x844`.
- Current default inspection measured `clientWidth=656` and `scrollWidth=656`.
- Current `390x844` inspection measured `clientWidth=390` and `scrollWidth=390`.
- Current `390x844` first primary element ids began with
  `inbox-attention-summary`, `inbox-queue-summary`, then the `Needs You` run
  section, preserving the attention/queue/work before setup hierarchy.
- The first run link from the inbox opened the deterministic waiting-decision
  run, proving the `Needs You` lane is reachable from the top of the inbox.
- Product-visible proof metadata is absent from the primary header path.

Run detail checks:

- `#run-thread` present.
- `#run-nav-thread`, `#run-nav-decisions`, `#run-nav-message`, and
  `#run-nav-evidence` present.
- `#run-conversation` or `#run-turn-summary` present.
- `#pending-permission-card` or `#run-permission-audit` present.
- `#run-security-boundary` present.
- On the disconnected waiting run, `#run-control-panel` remains available but no
  longer has the mobile `sticky` class while prompting is disabled.
- A waiting permission card presents prompt context, consequence, and action
  buttons first; policy chips, request ids, option summaries, and raw input are
  available inside the closed `#pending-permission-details` / `Review details`
  disclosure.
- The waiting card title was `Write file`; the decision summary read as a human
  approval prompt rather than raw ACP JSON.
- Run facts/details are available without dominating the primary header.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default/current browser width or `390x844`.
- Current default inspection measured `clientWidth=656` and `scrollWidth=656`.
- Current `390x844` inspection measured `clientWidth=390` and `scrollWidth=390`.
- Current `390x844` first primary element ids included `run-section-nav`,
  `run-thread`, and `pending-permission-card` before evidence/detail sections;
  `#pending-permission-details` remained closed by default.
- Product-visible proof metadata is absent from the primary header path.

This smoke record verifies the internal-alpha browser sanity gate at verified
application commit `7e91983a`. It does not change the production-grade boundary:
real-agent Haven-mediated file and terminal capability proof remains unproven
except for the explicit negative capability-gap artifacts named in the probe
documentation. It does strengthen the UI/UX evidence that the mobile-first
inbox/run hierarchy is usable for many concurrent runs: attention, lane counts,
the selected run, thread navigation, and the active human decision all appear
before secondary setup, evidence, and raw-detail surfaces.
