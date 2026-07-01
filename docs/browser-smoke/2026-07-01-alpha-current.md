# Browser Smoke: Current Alpha Candidate

Date: 2026-07-01

Verified application commit: `26de37b1`

Purpose: rerun the browser sanity gate after the workspace security policy and
current real-agent probe refresh, using the current dev server at
`http://127.0.0.1:4000/`.

## CLI Preconditions

- `MIX_ENV=dev mix haven.pending_migrations`
  - Result: `No pending migrations.`
- `MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000`
  - Result: passed.
  - Runtime smoke run id: `3223240c-67e0-49dc-abf1-3be3e53bf353`
  - Runtime smoke run URL:
    `http://127.0.0.1:4000/runs/3223240c-67e0-49dc-abf1-3be3e53bf353`
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
- `#inbox-search-form` present.
- `#new-run-panel` present as a secondary disclosure.
- Duplicate `#inbox-run-filters` absent.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default or `390x844`.
- Product-visible proof metadata is absent from the primary header path.

Run detail checks:

- `#run-thread` present.
- `#run-nav-thread`, `#run-nav-decisions`, `#run-nav-message`, and
  `#run-nav-evidence` present.
- `#run-conversation` or `#run-turn-summary` present.
- `#pending-permission-card` or `#run-permission-audit` present.
- `#run-security-boundary` present.
- Run facts/details are available without dominating the primary header.
- Page does not contain a pending migration or server error page.
- No horizontal overflow at default or `390x844`.
- Product-visible proof metadata is absent from the primary header path.

This smoke record verifies the internal-alpha browser sanity gate at verified
application commit `26de37b1`. It does not change the production-grade
boundary: real-agent Haven-mediated file and terminal capability proof remains
unproven for `codex-acp`.
