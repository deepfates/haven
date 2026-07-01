# Haven

Haven is a Phoenix/OTP application for running ACP coding agents outside an IDE.

The core shape:

- A durable run is stored in SQLite.
- Each live run is owned by a supervised `RunServer` process.
- The run process owns an ACP client connection to an external agent process.
- Meaningful state transitions are appended as events.
- LiveView renders an attention inbox and a run timeline from persisted state.
- Permission requests become explicit decisions.
- Reload reconstructs the run from the event log.

See [docs/design-requirements.md](docs/design-requirements.md) for the product
and system requirements guiding the project. See
[docs/validation-matrix.md](docs/validation-matrix.md) for what is currently
proved by tests and browser smoke, and what remains unproven.

## Run

```bash
mix ecto.setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000).

The inbox can save frequently used workspace directories and reuse them from
the run form's saved-workspace picker. Manual workspace paths still work.

The run page includes sample controls:

- `Echo` sends a complete prompt turn.
- `Ask permission` triggers a permission request.
- The approval card resolves the permission and lets the stub finish the turn.

In development, there are HTTP controls for deterministic local testing:

```bash
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/echo
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/permission
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/read-file
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/write-file
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/terminal
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/permissions/1/allow
curl -X POST http://127.0.0.1:4000/dev/runs \
  -H 'content-type: application/json' \
  -d '{"title":"Malformed smoke","agent":"malformed-agent","workspace":"'"$PWD"'"}'
```

With `mix phx.server` running, the repeatable runtime smoke exercises the same
rendered dev-server path and deterministic controls:

```bash
MIX_ENV=dev mix haven.runtime_smoke
MIX_ENV=dev mix haven.runtime_smoke --load-runs 3
```

It checks dev migrations, renders the inbox, creates a stub-backed run through
`/dev/runs` in a disposable workspace, waits for startup events on the run
page, triggers and resolves a generic permission request, approves ACP file
read/write requests, verifies the written file, runs a deterministic terminal
command, and verifies the thread/decision/evidence disclosure surfaces in
rendered HTML. With `--load-runs N`, it also creates N additional disposable
runs, alternates ordinary and bounded long-output turns, reloads the rendered
pages, and checks cross-run isolation.

To probe any configured ACP agent through Haven's real run lifecycle:

```bash
mix haven.agent_probe --agent stub-acp --workspace . --prompt "hello"
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "summarize this repo"
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "read README.md" --resolve-permissions allow
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "run tests" --expect-event terminal_created --expect-event terminal_output_succeeded --expect-event-field terminal_output_succeeded:payload.exit_status=0
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "run tests" --report docs/probes/my-agent-terminal.json
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "summarize this repo" --load-runs 2 --require-real-agent --report docs/probe-load/my-agent-load.json
mix haven.agent_probe --list-agents --preflight --workspace /path/to/repo
mix haven.agent_probe --list-agents --registry --workspace /path/to/repo
```

Configured agents can be supplied at runtime with `HAVEN_AGENTS_JSON`:

```bash
export HAVEN_AGENTS_JSON='{
  "my-agent": {
    "executable": "my-acp-agent",
    "args": ["--stdio", "--workspace", "{workspace}"],
    "cwd": "{workspace}",
    "env": {"TOKEN": "..."}
  }
}'
```

`executable` may be an absolute path or a command on `PATH`. `{workspace}` is
substituted in `args`, `cwd`, and `env` values before Haven starts the agent.
Agents can also be stored in SQLite through the inbox Agent Setup form or
`Haven.Agents.create_agent_config/1`; the inbox supports basic create, edit,
and delete for persisted commands, and persisted agent keys appear in the run
picker alongside runtime configuration.

The probe creates a durable run, waits for ACP initialization/session creation,
sends the prompt through `RunServer`, optionally resolves permission stalls, and
prints the persisted event timeline. Repeated `--expect-event` flags make the
probe fail unless the run emits the required Haven event types, turning
real-agent checks into acceptance contracts instead of best-effort smoke.
Repeated `--expect-event-field EVENT:payload.path=value` flags also require
specific event payload facts, such as the requested path, terminal command,
permission decision, or exit status.
Use `--list-agents --preflight` first when a saved command merely looks
plausible: it starts a short durable run for each probe candidate and verifies
the ACP initialize/session handshake before you attempt a full evidence report.
Use `--list-agents --registry` to fetch the public ACP Registry and print
npx-backed agent command suggestions that can be supplied through
`HAVEN_AGENTS_JSON`. Registry commands download and run third-party code; run
preflight and evidence probes only with an approved workspace and auth scope.
`--report path.json` writes the full report as pretty JSON for committed proof
artifacts. `--load-runs N` repeats the same real-agent probe as distinct
durable runs and writes an aggregate report when paired with `--report`.
Passing the probe with `stub-acp` proves the harness; passing it with a real
configured ACP agent is the next integration milestone. See
`docs/probes/README.md` and `docs/probe-load/README.md` for the report
requirements that make a probe count as real-agent evidence.

## Shape

- `Haven.Runs.RunServer` owns one live agent run.
- `Haven.Agents` resolves built-in and configured ACP agent commands.
- `Haven.PortIO` bridges spawned agent ports to the IO shape expected
  by `agent_client_protocol`.
- `Haven.WorkspaceFiles` handles workspace-scoped file capability requests.
- `Haven.Runs` is the run lifecycle context.
- `Haven.Events` is the append-only event log.
- `InboxLive` is the attention inbox.
- `RunLive` is the run timeline and control surface.
- `priv/agent_stub.exs` is an ACP-backed JSON-lines stub agent.

The default development agent is a self-contained ACP stub. Configured agent
keys can point at another ACP command and can be selected when starting a run,
alongside an explicit workspace path. File capability callbacks are proven
against deterministic ACP requests, and terminal create/wait/output/release is
proven for short-lived non-interactive commands. The next milestone is to
validate one real external agent and harden capability policy while keeping the
run/event/LiveView shape.
