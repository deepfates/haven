# Run Recovery Guide Smoke

Date: 2026-07-01

Target: `http://127.0.0.1:4000/runs/dc1acef5-d617-433c-8e43-65e2e6c164fd`

## Claim

When a run fails, Haven should explain the recovery choices in the run thread
before the user clicks an action.

## Check

- Opened a failed run with a valid workspace in the in-app browser.
- Confirmed the recovery card title was `Run failed`.
- Confirmed the latest failure reason was visible.
- Confirmed the recovery guide explained:
  - `Continue`: start a fresh ACP session and send a new instruction.
  - `Retry`: start a fresh ACP session and resend the last user prompt.
  - `Restart`: start a fresh ACP session without sending a prompt yet.
- Confirmed the restart and retry buttons expose matching `title` text.

## Result

Passed. Failed-run recovery is no longer only a row of action buttons; the run
thread explains what each recovery path will do while preserving the existing
history.
