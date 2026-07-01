# Browser Smoke: Current Alpha Candidate

Date: 2026-07-01

Verified application commit: `03657003`

Purpose: rerun the browser sanity gate after the mediated-capability negative
probe evidence commit, using the current dev server at `http://127.0.0.1:4000/`.

## CLI Preconditions

- `MIX_ENV=dev mix haven.pending_migrations`
  - Result: `No pending migrations.`
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000`
  - Result: passed.
  - Runtime smoke run id: `e1d746a8-12f2-44f2-ac66-aa8e8686f0b5`
  - Runtime smoke run URL:
    `http://127.0.0.1:4000/runs/e1d746a8-12f2-44f2-ac66-aa8e8686f0b5`

## Browser Checks

Target pages:

- `http://127.0.0.1:4000/`
- `http://127.0.0.1:4000/runs/e1d746a8-12f2-44f2-ac66-aa8e8686f0b5`

Viewports:

- Current/default in-app browser viewport.
- Mobile override: `390x844`.

Inbox checks:

- `#haven-inbox` rendered.
- `h1` text is `Inbox`.
- `#inbox-queue-summary` present.
- `#inbox-search-form` present.
- `#new-run-advanced` present as a secondary disclosure.
- Duplicate `#inbox-run-filters` absent.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default or `390x844`.
- Product-visible proof metadata is absent from the primary header path.

Run detail checks:

- Runtime smoke run rendered with title `Runtime smoke 1782892143867`.
- `#run-thread` present.
- `#run-nav-thread`, `#run-nav-decisions`, `#run-nav-message`, and
  `#run-nav-evidence` present.
- Run facts/details are available without dominating the primary header.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default or `390x844`.
- Product-visible proof metadata is absent from the primary header path.

Console checks:

- Browser console error/warning log check returned no entries for inbox and run
  detail at both checked viewport sizes.

This smoke record verifies the internal-alpha browser sanity gate at verified
application commit `03657003`. It does not change the production-grade
boundary: real-agent Haven-mediated file and terminal capability proof remains
unproven for `codex-acp`.
