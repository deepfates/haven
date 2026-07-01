# Browser Smoke: Runtime And Responsive Hierarchy

Date: 2026-07-01

Purpose: verify the current dev server renders the production-trunk hierarchy in
an actual browser after the UI simplification passes: plain inbox, plain run
thread, human controls first, evidence/details still inspectable on demand.

## Runtime Gate

Commands:

```bash
MIX_ENV=dev mix haven.pending_migrations
MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4000
```

Result:

- `haven.pending_migrations`: `No pending migrations.`
- `haven.runtime_smoke`: passed.
- Runtime smoke run:
  `http://127.0.0.1:4000/runs/0d246df6-e292-4fbe-b91f-98d7e898f0a2`
- Disposable workspace:
  `/var/folders/9l/xc7nlb_s3l5_n82ht5r89dtc0000gn/T/haven-runtime-smoke-2691`

## Browser Checks

In-app browser fresh-tab checks against `http://127.0.0.1:4000/`:

- Inbox rendered with `#haven-inbox` and `h1` = `Inbox`.
- `#inbox-queue-summary` present.
- Duplicate `#inbox-run-filters` absent.
- `#new-run-panel`, `#inbox-search-form`, `#workspaces-panel`, and
  `#agent-configs-panel` present.
- Desktop/default viewport had no page-level horizontal overflow.

Mobile viewport check at `390x844`:

- Inbox had no page-level horizontal overflow.
- Queue and search regions fit within the viewport.
- Runtime-smoke run page rendered `#haven-run`.
- Run header proof metadata remained absent:
  `#run-header-facts` and `#run-header-agent` were absent.
- Run details/evidence remained inspectable:
  `#run-facts-agent`, `#run-evidence-summary`, and `#run-permission-audit`
  were present.
- Product-visible developer samples remained absent:
  `#sample-prompts-disclosure` was absent.
- `#run-prompt-form` and `#run-thread` were present.
- Run page had no page-level horizontal overflow.
- Browser console error/warning log check returned no entries.

Note: an old in-app browser tab was already on a Chromium connection-refused
error page for `127.0.0.1`; opening a fresh in-app browser tab reached the
running dev server successfully. Shell `curl` and the fresh browser tab both
confirmed the app was available.
