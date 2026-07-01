# Permission Button Consequences Smoke

Date: 2026-07-01

Target: `http://127.0.0.1:4000/runs/84848506-298d-4619-887d-4ed91e2fa4ab`

## Claim

When a run is waiting on a permission decision, the primary action buttons
should be self-describing. A user should not have to cross-reference raw JSON or
nearby explanatory text to understand what an action will do.

## Check

- Opened a waiting run with a pending file-write permission request.
- Confirmed the pending permission card rendered `Write file`.
- Confirmed the allow button title and aria label explained that allowing lets
  the agent proceed with the write request.
- Confirmed the deny button title and aria label explained that denying blocks
  the request and returns the denial to the agent.
- Confirmed the cancel button title and aria label explained that it cancels
  the turn and resolves outstanding decisions as cancelled.

## Result

Passed. Permission decisions are now clearer at the action target itself, which
is especially important on mobile where the user may focus the button before
reviewing surrounding details.
