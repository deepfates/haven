# Quickstart

This repo runs a local ACP bridge + web UI. Your "haven" is simply the machine running these processes.

## Prerequisites

- Bun (for the bridge + UI dev server)
- Node/npm if you use the default `AGENT_COMMAND` (`npx @zed-industries/claude-code-acp`)

## Install

From the repo root:

```bash
bun install
cd server && bun install
cd ../client && bun install
```

## Run (dev)

From the repo root:

```bash
bun run dev
```

This starts:

- Bridge server on `http://localhost:8090`
- Vite dev server on `http://localhost:8080`

Open `http://localhost:8080` in a desktop browser or on your phone (same network).

## Run (production-ish)

```bash
bun run build
cd server && bun run start
```

The bridge serves the built UI from `client/dist` on `http://localhost:8080` by default.

## Common overrides

```bash
# Use a different working directory for agent sessions
DEFAULT_CWD=/path/to/workspace

# Use a different ACP agent command
AGENT_COMMAND="/path/to/agent --acp"

# Move the bridge to a different port
PORT=9000
```

For a separately hosted UI, set the WebSocket URL at build time:

```bash
VITE_WS_URL=wss://your-host/ws
```

## Notes for Sprites

If you run this on a remote machine (Sprite or otherwise), you are responsible for provisioning and access control. There is no built-in auth yet.
