# Elixir Cutover Notes

Haven has been cut over from the TypeScript/Bun/Vite implementation to the
Phoenix/LiveView implementation.

The project intent did not change: Haven is a non-IDE ACP client centered on
durable agent runs, inspectable event history, and explicit human decisions.
The implementation changed because Phoenix, LiveView, and OTP are a better fit
for long-lived agent sessions than a browser-to-bridge WebSocket app.

## What Was Preserved

- Multi-run inbox as the primary attention surface.
- Run detail timeline with persisted events.
- ACP over stdio between Haven and an agent process.
- Permission requests represented as first-class UI decisions.
- SQLite persistence for runs and events.
- Reloadable run state.
- Explicit protocol design documentation.

## What Was Removed

- The custom browser-to-bridge JSON-RPC WebSocket API.
- The Bun server process.
- The Vite/React client.
- Playwright and Bun tests tied to that two-process architecture.
- Root Node package manifests and lockfiles.

Those pieces were implementation scaffolding for the old architecture, not the
product core. LiveView now owns browser updates directly, and
`agent_client_protocol` owns ACP request/response correlation.

## Legacy Behavior To Rebuild In Elixir

The old implementation had useful behavioral coverage. These should become
Elixir tests or LiveView/browser tests as the cutover matures:

- Creating a run from the inbox opens a ready run detail view.
- Sending a prompt streams an agent response.
- Permission requests survive reload and resolve the exact pending request.
- Agent process death fails pending turns instead of hanging.
- Request ids are isolated per run/connection.
- Archived or closed runs can be hidden from the default inbox.
- Unknown or unsupported ACP update types are visible or explicitly ignored.

## Deliberate API Change

The old app exposed browser JSON-RPC methods such as `session/list`,
`session/new`, `session/get`, `session/prompt`, and `session/respond` over
`/ws`. The cutover does not preserve that as a public API.

The canonical UI is now server-rendered LiveView. If Haven later needs a public
API, it should be designed around the durable run model rather than carrying the
old bridge API forward by inertia.

