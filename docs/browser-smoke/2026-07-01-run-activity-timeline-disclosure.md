# Run Activity Timeline Disclosure Smoke

Date: 2026-07-01

Purpose: verify the run detail page defaults to a conversation/work surface instead of a raw event log, while preserving inspectable evidence on demand.

Target: `http://127.0.0.1:4000/runs/6f1d7db2-7a3e-4149-81d1-08ffcfc93b17`

Observed after reload:

- `#haven-run` rendered for an existing failed run.
- `#run-activity-timeline` rendered as a `<details>` disclosure.
- `#run-activity-timeline` open state: `false`.
- Timeline summary text: `Activity timeline Raw protocol, tool, file, terminal, and runtime events 3`.
- Nested `#timeline-filters` remained present for inspection but had a zero-size visual box while the parent timeline was closed.
- First raw event card `#event-1` remained in the DOM but had a zero-size visual box while the parent timeline was closed.

Verification commands:

- `mix test test/haven_web/live/run_live_test.exs`

