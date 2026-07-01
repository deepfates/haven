# Run Attention Title Smoke

Date: 2026-07-01

Target: `http://127.0.0.1:4000/runs/d693199f-b21e-4750-bc8a-d054a402e379`

## Claim

While reading one run, Haven should still surface other runs that need the
user's attention through ordinary browser/app idioms.

## Check

- Reloaded a run detail page in the in-app browser.
- Confirmed the document title was `(10) Browser missing workspace check -
  Haven`.
- Confirmed the inbox link badge rendered `10 need you`.

## Result

Passed. The run detail page no longer only surfaces unread updates from other
runs; it also surfaces other waiting/failed runs that already need a decision or
recovery.
