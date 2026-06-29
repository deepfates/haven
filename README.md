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

The run page includes sample controls:

- `Echo` sends a complete prompt turn.
- `Ask permission` triggers a permission request.
- The approval card resolves the permission and lets the stub finish the turn.

In development, there are HTTP controls for deterministic local testing:

```bash
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/echo
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/sample/permission
curl -X POST http://127.0.0.1:4000/dev/runs/RUN_ID/permissions/1/allow
curl -X POST http://127.0.0.1:4000/dev/runs \
  -H 'content-type: application/json' \
  -d '{"title":"Malformed smoke","agent":"malformed-agent","workspace":"'"$PWD"'"}'
```

To probe any configured ACP agent through Haven's real run lifecycle:

```bash
mix haven.agent_probe --agent stub-acp --workspace . --prompt "hello"
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "summarize this repo"
mix haven.agent_probe --agent my-agent --workspace /path/to/repo --prompt "read README.md" --resolve-permissions allow
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

The probe creates a durable run, waits for ACP initialization/session creation,
sends the prompt through `RunServer`, optionally resolves permission stalls, and
prints the persisted event timeline. Passing the probe with `stub-acp` proves
the harness; passing it with a real configured ACP agent is the next integration
milestone.

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
