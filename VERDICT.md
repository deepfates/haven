# VERDICT: REFUTED

Branch reviewed: `inbox-inversion`

The branch improves the rendered inbox counts and history pagination, but it does not satisfy the ticket's first hard requirement: `Start a run` is not at the top of the rendered DOM. It is visually reordered with CSS classes after the attention/history wall.

## Claim 1: Start a run at the top of the rendered page

Verdict: FAIL.

Evidence from the dev server rendering against `haven_dev.db`:

```sh
mix phx.server
curl -s http://localhost:4000/ -o /tmp/haven_inbox.html -w '%{http_code} %{size_download}\n'
rg -n '(<title>|id="new-run-panel"|id="inbox-run-filters"|id="inbox-attention-summary"|id="inbox-history-section"|id="inbox-history-page-count"|id="show-more-history"|id="inbox-queue-needs_you"|id="inbox-attention-label")' /tmp/haven_inbox.html
```

Observed order in rendered HTML:

```text
24: id="inbox-attention-summary"
1379: id="inbox-history-section"
3610: id="new-run-panel"
3822: id="inbox-run-filters"
```

The source HEEx has the same structural order: attention summary and run sections precede `#new-run-panel`; the new run panel relies on `class="order-2"` while earlier sections use later order classes. The ticket explicitly asked for DOM/rendered order, not just visual order.

## Claim 2: Pagination with the dev DB

Verdict: PASS for initial render; PASS for event behavior in ExUnit coverage; browser-client verification unavailable.

Current `haven_dev.db` does not match the ticket's stated 161 smoke-test runs. At review time it contained 305 total runs, 302 active runs, and 163 active work runs.

Aggregate command:

```sh
sqlite3 haven_dev.db 'select count(*) from runs; select count(*) from runs where archived_at is null; select count(*) from runs where archived_at is null and purpose="work";'
```

Rendered dev HTML showed:

```text
Showing 25 of 149 history runs
```

and `#show-more-history` was present. Counting history row primary actions before pagination found exactly 25:

```sh
awk '/id="inbox-history-section"/{flag=1} /id="inbox-history-pagination"/{flag=0} flag' /tmp/haven_inbox.html | rg -o 'id="run-[^"]+-primary-action"' | wc -l
```

Output:

```text
25
```

`test/haven_web/live/inbox_live_test.exs` includes a focused LiveView test that clicks `#show-more-history` and verifies the page grows from 25 to 26 rows; that focused file passed. The in-app browser was unavailable in this session (`agent.browsers.list()` returned `[]`), and a dev-env one-off LiveViewTest probe was blocked by test-only `lazy_html`, so I did not independently click the live dev page in a browser.

## Claim 3: Missing workspace badge exclusion

Verdict: PASS for the inbox LiveView; discovered gap outside this LiveView.

Dev DB aggregate command:

```sh
mix run -e 'Application.ensure_all_started(:haven); alias Haven.Runs; runs = Runs.list_runs(); work = Enum.reject(runs, &(&1.purpose == "diagnostic")); missing? = fn r -> not File.dir?(r.workspace) end; missing = Enum.count(work, missing?); needs = Enum.filter(work, fn r -> not missing?.(r) and (r.status in ["waiting", "failed"] or (r.status in ["initializing", "running"] and not Runs.started?(r))) end); history = Enum.reject(work, fn r -> Enum.any?(needs, &(&1.id == r.id)) end); IO.inspect(%{active_work: length(work), missing_workspaces: missing, needs_you_after_exclusion: length(needs), history: length(history), missing_by_status: work |> Enum.filter(missing?) |> Enum.frequencies_by(& &1.status)})'
```

Observed:

```elixir
%{
  active_work: 163,
  missing_workspaces: 81,
  needs_you_after_exclusion: 14,
  history: 149,
  missing_by_status: %{"failed" => 1, "idle" => 78, "initializing" => 1, "running" => 1}
}
```

Rendered inbox badge showed `14 runs need you`, not 94. The history count was 149, consistent with missing-workspace rows remaining inspectable as history instead of inflating Needs You.

However, `Haven.Runs.attention_summary/1` still counts `missing_workspace?/1` as an attention category in `lib/haven/runs.ex`, while `HavenWeb.InboxLive` excludes it locally. I filed this as a discovered ticket because other callers can still reproduce the corpse-count bug outside the inbox LiveView.

## Test Runs

Commands run:

```sh
mix test test/haven_web/live/inbox_live_test.exs
mix test
mix precommit
```

Results:

- `mix test test/haven_web/live/inbox_live_test.exs`: 61 tests, 0 failures.
- `mix test`: 327 tests, 0 failures.
- `mix precommit`: first escalated run failed with one SQLite `Database busy` failure in `test/haven/workspaces_test.exs`; rerun passed with 327 tests, 0 failures.

The first `mix precommit` failure was filed as a discovered ticket because it is outside this inbox ticket but affects the required final gate.

## Filed Tickets

- `hav-pves`: precommit can fail from SQLite busy in workspace tests.
- `hav-sgnm`: `Runs.attention_summary` still counts missing workspaces as attention.

## Uncertainties

- I did not verify the `Show more` click in a real browser because the in-app browser connector was unavailable. I verified the dev DB initial render directly and the click behavior through the existing LiveView test suite.
- The dev DB had 163 active work runs, not the ticket's 161 smoke-test runs, at the time of review.
