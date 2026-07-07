# dee-acpc build report

Branch: `feat/cantrip-agent`

## What changed

- Registered `cantrip-familiar` as a built-in ACP agent when `CANTRIP_ROOT` or `config :haven, :cantrip_root` points at a cantrip checkout. Dev config points at the sibling fleet checkout.
- Completed two ACP client gaps hit during integration:
  - Haven now authenticates agents that advertise `authMethods` during `initialize`.
  - Haven now injects configured MCP servers from `config :haven, :mcp_servers` into `session/new`, with `{workspace}` substitution.
- Hardened stdio handling for real agents that print benign non-JSON startup/status lines while idle. Haven records `agent_output_ignored` instead of failing the run, while malformed output during active prompt work still fails.
- Added regression coverage for cantrip agent resolution, advertised auth, MCP server injection, and idle non-protocol stdout.

## Reproduce commands

```sh
cd /Users/deepfates/Hacking/github/deepfates/haven
git checkout feat/cantrip-agent
mix format
mix test test/haven/agent_probe_test.exs:633 test/haven/agent_probe_test.exs:659 test/haven/agent_probe_test.exs:682 test/haven/agents_test.exs:35 test/haven/agents_test.exs:47
mix test test/haven/agents_test.exs test/haven/agent_probe_test.exs
mix haven.agent_probe --agent cantrip-familiar --workspace . --prompt "Reply with one short sentence confirming you are running through Haven." --timeout 120000 --expect-event agent_initialized --expect-event agent_session_started --expect-event turn_finished --expect-min-agent-message-chunks 1 --report docs/probes/cantrip-familiar-basic.json --show-events
mix precommit
git status --short
git log -1 --oneline
```

## Evidence

- `mix format` passed.
- Focused new regressions passed: 5 tests, 0 failures.
- `mix test test/haven_web/live/run_live_test.exs:1820` passed after updating the stale-disconnect assertion to drive the LiveView event directly instead of clicking an already-disabled button.
- `mix precommit` passed: probe reports validated; 332 tests, 0 failures.
- Real cantrip launch improved past Haven's previous failure mode: Haven now ignores cantrip's non-JSON startup/build output while idle instead of failing an established session.
- Real cantrip turn remains blocked by the sibling cantrip checkout failing to compile before ACP initialize completes. The failed command output reported undefined functions in `/Users/deepfates/Hacking/github/deepfates/cantrip/lib/cantrip/entity_server.ex`, including `reply_pending/2`, `reply_running/2`, `stop_runner/2`, `running_kind/1`, `append_control_event/4`, `close_loom/1`, `control_event/3`, `send_runner_control/2`, `append_boundary_steer/2`, `enqueue_pending/4`, `reply_all_pending_runner_down/2`, `start_next_pending/1`, and `pending_empty?/1`.
- Because cantrip does not compile, I could not produce the requested real cantrip turn or permission-decision proof in this branch. I did not commit failed positive probe JSON under `docs/probes`.

## Filed tickets

- `dee-fkvx` - cantrip familiar ACP checkout does not compile under Haven launch.
