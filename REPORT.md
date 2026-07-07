# dee-inbx build report

Branch: `inbox-inversion`

## What changed

- Changed the shared `Runs.attention_summary/1` classifier so missing-workspace runs do not add a `needs_you`/`workspaces` attention category.
- Updated the focused regressions for the attention badge: an idle run whose workspace vanished no longer increments the shared summary, run-detail header badge, or run-detail browser title count.
- Left the already-passed inbox DOM-order inversion and history pagination work untouched.

## Reproduce commands

```sh
git worktree add --detach /private/tmp/dee-inbx-build inbox-inversion
cd /private/tmp/dee-inbx-build
mix deps.get
mix format lib/haven/runs.ex test/haven/runs_test.exs test/haven_web/live/run_live_test.exs
mix test test/haven/runs_test.exs:51 test/haven_web/live/run_live_test.exs:436
mix test test/haven/runs_test.exs
mix test test/haven_web/live/run_live_test.exs
mix test test/haven_web/live/run_live_test.exs:3845
mix test
mix precommit
git status --short
git log -1 --oneline
```

Coordinator fast-forward command from the main checkout:

```sh
git checkout inbox-inversion
git merge --ff-only /private/tmp/dee-inbx-build
```

## Evidence

- `mix deps.get` completed in the detached worktree. It also reported Hex security advisories; that was filed separately as `hav-8oa2`.
- `mix format lib/haven/runs.ex test/haven/runs_test.exs test/haven_web/live/run_live_test.exs` passed after rerunning with local Mix PubSub socket permissions.
- `mix test test/haven/runs_test.exs:51 test/haven_web/live/run_live_test.exs:436` passed: 2 tests, 0 failures.
- `mix test test/haven/runs_test.exs` passed: 24 tests, 0 failures.
- `mix test test/haven_web/live/run_live_test.exs` failed: 78 tests, 1 failure. The failure is existing ticket `dic-bsqj`: `test/haven_web/live/run_live_test.exs:3845` expected `agent_session_started` but got `agent_protocol_failed` because `priv/agent_stub.exs` could not call `Haven.ACPWire.decode!/1`.
- `mix test test/haven_web/live/run_live_test.exs:3845` reproduced the same `dic-bsqj` failure alone: 1 test, 1 failure.
- `mix test` failed with the same single `dic-bsqj` failure: 327 tests, 1 failure.
- `mix precommit` failed with the same single `dic-bsqj` failure after validating probe reports: 327 tests, 1 failure.

## Filed tickets

- `hav-8oa2` - Haven deps include Hex security advisories.
- Existing tickets observed but not duplicated: `dic-bsqj` covers the configured-stub ACP failure blocking full-suite/precommit green; `hav-sgnm` is the attention-summary defect fixed by this bounce; `hav-u19f` covers the stale Git `gc.log` warning emitted while committing.
