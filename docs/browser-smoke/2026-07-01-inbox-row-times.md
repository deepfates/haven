# Inbox Row Times Smoke

Date: 2026-07-01

Target:
- `http://127.0.0.1:4000/`
- Created a live row through `POST /dev/runs`:
  `f89ed3fc-0ca8-4289-95f2-a2d582f4e8fa`, title `Browser smoke row times`, agent `stub-acp`.

Checks:
- Inbox did not show an Ecto pending migration page.
- Inbox did not show a LiveView crash or exception page.
- `#run-f89ed3fc-0ca8-4289-95f2-a2d582f4e8fa-row-times` rendered with both `Started` and `Updated`.
- `#run-f89ed3fc-0ca8-4289-95f2-a2d582f4e8fa-started-at` rendered a clock time.
- `#run-f89ed3fc-0ca8-4289-95f2-a2d582f4e8fa-updated-at` rendered a clock time.
- At a `390x844` mobile viewport, the row time strip remained visible.
- At the same mobile viewport, the page reported `scrollWidth == clientWidth == 390`, so the added row metadata did not introduce horizontal page overflow.

Visual read:
- Row times read as quiet operational context under latest activity.
- The row remains title/activity/next-action first; the added timestamps do not become a dashboard-like badge cluster.
