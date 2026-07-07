# dee-inbx build report

Branch: `inbox-inversion`

## What changed

- Moved the first-viewport inbox priority to actions: `Start a run` is visually ordered above run queues, and `Find runs` follows it before attention/history.
- Added history pagination with a default page size of 25 and a `Show more` action.
- Changed inbox attention classification so runs whose workspace path no longer exists do not inflate `Needs You` counts or the browser title badge. They remain visible as history rows with the existing `Workspace missing` row state.
- Left the run-detail page untouched.

## Reproduce commands

```sh
git checkout inbox-inversion
mix test test/haven_web/live/inbox_live_test.exs
mix test
mix precommit
```

## Evidence

- `mix test test/haven_web/live/inbox_live_test.exs` passed: 61 tests, 0 failures.
- `mix test` passed: 327 tests, 0 failures.
- `mix precommit` passed after rerunning with local socket permissions: probe reports validated, 327 tests, 0 failures.

## Filed tickets

- `hav-u19f` — Repo auto-gc is blocked by stale gc.log.
