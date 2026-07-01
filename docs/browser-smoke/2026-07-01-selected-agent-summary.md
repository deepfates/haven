# Selected Agent Summary Smoke

Date: 2026-07-01

Purpose: verify the Start Run form surfaces selected-agent readiness before Advanced options, so users running many agents can confirm what will launch.

Target: `http://127.0.0.1:4000/`

Observed after reloading the inbox:

- `#new-run-agent-evidence` rendered in the primary Start Run form.
- Selected agent: `stub-acp`.
- `#new-run-agent-launch` text: `Launch ready`.
- `#new-run-agent-trust` text: `Local harness`.
- `#new-run-agent-auth-env` text: `No auth env`.
- `#new-run-agent-env-keys` text: `env none`.
- `#new-run-agent-evidence` appeared before `#new-run-advanced` in `#new-run-form`.

Verification commands:

- `mix test test/haven_web/live/inbox_live_test.exs`

