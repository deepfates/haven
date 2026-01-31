# ACP Protocol Reference

Quick reference for building ACP clients. Based on [agentclientprotocol.com](https://agentclientprotocol.com).

## Message Flow

```
Client                              Agent
  |                                   |
  |-- initialize ------------------>  |
  |<-- result: capabilities --------  |
  |                                   |
  |-- session/new ----------------->  |
  |<-- result: { sessionId } -------  |
  |                                   |
  |-- session/prompt -------------->  |
  |<-- notification: session/update   |  (many)
  |<-- notification: session/update   |
  |<-- REQUEST: session/request_permission
  |-- response: { outcome } -------->  |
  |<-- notification: session/update   |
  |<-- result: { stopReason } ------  |
```

## Key Methods

### Client → Agent (Requests)

| Method | Purpose |
|--------|---------|
| `initialize` | Negotiate protocol version and capabilities |
| `session/new` | Create new session, returns `sessionId` |
| `session/prompt` | Send user message, triggers streaming updates |
| `session/cancel` | Notification to abort current prompt |

### Agent → Client (Notifications)

| Method | Purpose |
|--------|---------|
| `session/update` | Stream updates during prompt processing |

### Agent → Client (Requests)

| Method | Purpose |
|--------|---------|
| `session/request_permission` | Ask user to approve tool call |

## Session Update Types

The `session/update` notification has a `sessionUpdate` discriminator:

```typescript
type SessionUpdate =
  | { sessionUpdate: "user_message_chunk", content: ContentBlock }
  | { sessionUpdate: "agent_message_chunk", content: ContentBlock }
  | { sessionUpdate: "agent_thought_chunk", content: ContentBlock }
  | { sessionUpdate: "tool_call", ...ToolCall }
  | { sessionUpdate: "tool_call_update", ...ToolCallUpdate }
  | { sessionUpdate: "plan", entries: PlanEntry[] }
  | { sessionUpdate: "available_commands_update", ... }
  | { sessionUpdate: "current_mode_update", ... }
```

## Tool Call Structure

```typescript
type ToolCall = {
  id: string;          // Unique ID
  name: string;        // Tool name (e.g., "Read", "Bash")
  status: "pending" | "in_progress" | "completed" | "failed";
  kind?: "file" | "command" | "search" | "other";
  locations?: { path: string, line?: number }[];
  content?: ToolCallContent[];
  rawInput?: unknown;
  rawOutput?: unknown;
}
```

## Permission Request Flow

**Important:** Permission requests are NOT notifications - they're requests that require a response.

```typescript
// Agent sends REQUEST (has id)
{
  jsonrpc: "2.0",
  id: "perm_123",
  method: "session/request_permission",
  params: {
    sessionId: "sess_abc",
    toolCall: { id, name, status, ... },
    options: [
      { optionId: "allow", name: "Allow", kind: "allow_once" },
      { optionId: "reject", name: "Reject", kind: "reject_once" }
    ]
  }
}

// Client must RESPOND
{
  jsonrpc: "2.0",
  id: "perm_123",  // Same ID!
  result: {
    outcome: { outcome: "selected", optionId: "allow" }
    // OR: outcome: { outcome: "cancelled" }
  }
}
```

## Stop Reasons

Prompt response `stopReason`:
- `end_turn` - LLM finished normally
- `max_tokens` - Token limit hit
- `cancelled` - Client sent cancel notification
- `refusal` - Agent declined to continue

## Content Blocks

User prompts and agent messages use ContentBlock:

```typescript
type ContentBlock =
  | { type: "text", text: string }
  | { type: "image", mimeType: string, data: string }
  | { type: "audio", mimeType: string, data: string }
  | { type: "resource_link", uri: string, ... }
  | { type: "embedded_resource", ... }
```

## What Our Bridge Gets Wrong

1. **Discriminator**: We use `type` but ACP uses `sessionUpdate`
2. **Permission handling**: We treat it as notification, but it's a request needing response
3. **Message forwarding**: We don't properly forward permission requests to client

## Minimal Test Sequence

```javascript
// 1. Initialize
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1, capabilities: {} }})
// Wait for response

// 2. Create session
send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/home/sprite", mcpServers: [] }})
// Wait for response with sessionId

// 3. Send prompt
send({ jsonrpc: "2.0", id: 3, method: "session/prompt", params: {
  sessionId: "...",
  prompt: [{ type: "text", text: "say hello" }]
}})
// Handle session/update notifications
// Handle session/request_permission REQUESTS (respond!)
// Wait for final response with stopReason
```
