# dee-inbx build report

Branch: `inbox-inversion`

## What changed

- Moved the first-viewport inbox priority to actions in real DOM order: `Start a run` now renders immediately after the inbox header, and `Find runs` follows it before attention, history, diagnostics, archived, and setup sections.
- Updated the inbox hierarchy regression test to assert rendered HTML element order by DOM IDs instead of CSS order classes.
- Added history pagination with a default page size of 25 and a `Show more` action.
- Changed inbox attention classification so runs whose workspace path no longer exists do not inflate `Needs You` counts or the browser title badge. They remain visible as history rows with the existing `Workspace missing` row state.
- Left the run-detail page untouched.

## Reproduce commands

```sh
git checkout inbox-inversion
mix format lib/haven_web/live/inbox_live.ex test/haven_web/live/inbox_live_test.exs
mix test test/haven_web/live/inbox_live_test.exs
mix test
mix precommit
```

## Evidence

- `mix format lib/haven_web/live/inbox_live.ex test/haven_web/live/inbox_live_test.exs` passed after rerunning with local Mix PubSub socket permissions.
- `mix test test/haven_web/live/inbox_live_test.exs` passed: 61 tests, 0 failures.
- `mix test` first hit an unrelated SQLite `Database busy` failure in `test/haven_web/live/run_live_test.exs:2317`; retry passed: 327 tests, 0 failures.
- `mix precommit` passed after rerunning with local Mix PubSub socket permissions: probe reports validated, 327 tests, 0 failures.

## Filed tickets

- None in this bounce. Prior review already filed `hav-pves` for SQLite busy precommit flakes and `hav-sgnm` for `Runs.attention_summary/1` counting missing workspaces outside the inbox LiveView.
