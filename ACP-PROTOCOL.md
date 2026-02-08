# ACP Bridge Reference

This file documents the two protocol hops in this repo:

1. Browser <-> bridge (JSON-RPC 2.0 over WebSocket)
2. Bridge <-> agent (ACP over stdio)

For the authoritative ACP spec, see agentclientprotocol.com.

## Browser <-> bridge (JSON-RPC)

WebSocket endpoint: `/ws`

### Requests

`session/list`
- Params: `{ archived?: boolean, status?: string[] }`
- Result: `{ sessions: [{ id, agentType, cwd, title, status, exitReason, createdAt, updatedAt }] }`

`session/new`
- Params: `{ agentType?: string, cwd?: string, title?: string }`
- Result: `{ sessionId }`

`session/get`
- Params: `{ sessionId: string, since?: number }`
- Result:
  ```json
  {
    "session": { "id": "...", "agentType": "...", "cwd": "...", "title": "...", "status": "...", "exitReason": null, "createdAt": "...", "updatedAt": "..." },
    "updates": [{ "seq": 1, "updateType": "agent_message_chunk", "payload": { "sessionUpdate": "agent_message_chunk", "...": "..." }, "createdAt": "..." }],
    "pendingRequests": [{ "requestId": "123", "requestType": "permission", "payload": { "...": "..." } }]
  }
  ```

`session/prompt`
- Params: `{ sessionId: string, prompt: ContentBlock[] }`
- Result: `{ success: true }`

`session/respond`
- Params: `{ sessionId: string, requestId: string, response: object }`
- Result: `{ success: true }`

`session/cancel`
- Params: `{ sessionId: string }`
- Result: `{ success: true }`

`session/archive`
- Params: `{ sessionId: string }`
- Result: `{ success: true }`

`session/sync`
- Alias for `session/get` (legacy clients).

### Notifications

`session/updated`
- Params: `{ sessionId: string, updates: [{ seq, updateType, payload }] }`
- `payload` is the ACP `update` object, including `sessionUpdate`.

`session/status_changed`
- Params: `{ sessionId: string, status: string, exitReason?: string }`

`session/request`
- Params: `{ sessionId: string, requestId: string|number, request: object }`
- `request` is the ACP request params (typically `session/request_permission`).

### Update types the UI handles

- `user_message_chunk`
- `agent_message_chunk`
- `tool_call`
- `tool_call_update`
- `plan`

Other ACP update types are currently ignored by the UI.

## Bridge <-> agent (ACP over stdio)

Message flow (simplified):

```
Bridge                          Agent
  |                               |
  |-- initialize -------------->  |
  |<-- result ------------------  |
  |                               |
  |-- session/new ------------->  |
  |<-- result: { sessionId } ---  |
  |                               |
  |-- session/prompt ---------->  |
  |<-- notification: session/update  (many)
  |<-- REQUEST: session/request_permission
  |-- response: { outcome } ---->  |
  |<-- notification: session/update
```

## Permission requests

Agents send `session/request_permission` as a JSON-RPC request. The bridge persists it and forwards it to the browser as `session/request`. The browser responds via `session/respond`, and the bridge forwards the response back to the agent using the original request id.

## Current gaps

- No session resume if an agent process exits.
- Non-text content blocks are not rendered in the UI.
- `agentType` is stored but does not select a different agent command.
