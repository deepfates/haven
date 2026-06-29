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
```

## Shape

- `Haven.Runs.RunServer` owns one live agent run.
- `Haven.Agents` resolves built-in and configured ACP agent commands.
- `Haven.PortIO` bridges spawned agent ports to the IO shape expected
  by `agent_client_protocol`.
- `Haven.Runs` is the run lifecycle context.
- `Haven.Events` is the append-only event log.
- `InboxLive` is the attention inbox.
- `RunLive` is the run timeline and control surface.
- `priv/agent_stub.exs` is an ACP-backed JSON-lines stub agent.

The default development agent is a self-contained ACP stub. Configured agent
keys can point at another ACP command, but the next milestone is to validate one
real external agent and implement file and terminal client capabilities while
keeping the run/event/LiveView shape.
