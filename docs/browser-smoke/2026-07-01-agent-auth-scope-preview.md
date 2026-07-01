# Agent Auth Scope Preview Browser Smoke

Date: 2026-07-01

Commit under test: working tree after `fe47b532`

URL: http://127.0.0.1:4000/

## Scenario

Verify the Start Run form shows selected-agent auth/environment scope before
launch, without leaking configured env values.

## Setup

Created a dev agent config through `Haven.Agents.create_agent_config/1`:

- key: `auth-preview-smoke`
- executable: `sh`
- args: `-c`, `cat`
- env keys: `API_TOKEN`, `MODE`
- env value used for negative leak check: `browser-secret`

## Result

In the in-app browser:

- Reloaded the inbox.
- Selected `auth-preview-smoke` from the Start Run agent picker.
- Verified `#new-run-agent-key` rendered `auth-preview-smoke`.
- Verified `#new-run-agent-auth-env` rendered `Credential env`.
- Verified `#new-run-agent-env-keys` rendered `env keys API_TOKEN, MODE`.
- Verified `#new-run-agent-auth-scope` title rendered:
  `Credential-like keys will be injected: API_TOKEN. Values stay hidden in Haven's launch evidence.`
- Verified the page text did not contain `browser-secret`.

Outcome: pass.
