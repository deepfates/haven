# Decision Evidence Link Smoke

Date: 2026-07-01

Purpose: verify a pending human decision points to the visible evidence disclosure instead of anchoring directly into hidden raw event content.

Target: `http://127.0.0.1:4000/runs/a2a7370a-c97f-4247-95f1-58f1e0145226`

Observed on an existing waiting run:

- `#pending-permission-card` rendered with the approval copy and primary decision actions.
- `#pending-permission-event-link` text: `Open activity timeline #event-8`.
- `#pending-permission-event-link` href: `#run-activity-timeline`.
- `#pending-permission-event-reference` text: `#event-8`.
- `#run-activity-timeline` rendered closed by default.
- Raw event `#event-8` remained in the DOM but had a zero-size visual box while the timeline disclosure was closed.

Verification commands:

- `mix test test/haven_web/live/run_live_test.exs`

