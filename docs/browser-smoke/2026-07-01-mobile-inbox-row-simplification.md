# Mobile Inbox Row Simplification Smoke

Date: 2026-07-01

Purpose: verify the inbox is moving toward a mobile-first conversation/work queue instead of a dashboard-style artifact list.

Target: `http://127.0.0.1:4000/`

Viewport: `390x844`

Observed before the final tightening pass:

- First urgent failed run row height: `157px`
- Archive button visible on phone
- Operational state repeated the same recovery signal already present in the attention badge

Observed after tightening the mobile row:

- First urgent failed run row height: `117px`
- Archive button display: `none` on phone
- Operational state display: `none` on phone
- Primary action remained visible: `Recover`
- Row still showed the essential triage path: title, workspace, agent, latest activity, next step, attention state, primary action

Verification notes:

- The row used for measurement was an existing failed run: `run-6f1d7db2-7a3e-4149-81d1-08ffcfc93b17`
- Browser DOM check confirmed `#haven-inbox` rendered
- Focused LiveView suite passed after the change: `mix test test/haven_web/live/inbox_live_test.exs`

