# Run Evidence Nav Labels Smoke

Date: 2026-07-01

Target: `http://127.0.0.1:4000/runs/5437fc40-660a-4699-b4a7-185582aea7aa`

## Claim

The run thread's top navigation should help a user scan file and terminal
activity without opening every evidence disclosure.

## Check

- Opened a run with one pending file change and one failed terminal session.
- Confirmed the Files nav count rendered `1` with title `1 pending` and aria
  label `File changes: 1 pending`.
- Confirmed the Terminals nav count rendered `1` with title `1 attention` and
  aria label `Terminal sessions: 1 attention`.

## Result

Passed. The run detail nav now exposes whether file or terminal evidence needs
review, not only how many records exist.
