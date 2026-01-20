# ACP Mobile Client

A mobile-first web client for AI coding agents, built on the Agent Client Protocol.

---

## The Idea

Open a URL on your phone. See your agents. Tap one, watch it work. Approve when needed. Redirect with a message. That's it.

No terminal. No code editor (yet). Just an inbox and activity feeds.

---

## Why ACP

ACP (Agent Client Protocol) is LSP for AI agents. It defines how clients talk to agents:

- `session/new` → start conversation
- `session/prompt` → send message
- `session/update` → streaming events (messages, tool calls, file locations)
- `session/request_permission` → agent asks for approval

Any ACP client works with any ACP agent (Claude Code, Goose, Gemini CLI, etc.)

Building on the protocol means:
- Interoperable with Zed, Neovim, JetBrains
- Future-proof as ACP evolves
- Not reinventing message formats

---

## Architecture

```
┌─────────────────────────────────────┐
│  Mobile Browser (PWA)               │
│  ├── Inbox view (sessions list)     │
│  ├── Activity feed (per session)    │
│  ├── Approval cards                 │
│  └── Chat input                     │
└──────────────────┬──────────────────┘
                   │
                   │ WebSocket (JSON-RPC 2.0)
                   │
┌──────────────────▼──────────────────┐
│  ACP Bridge (on Sprite)             │
│  ├── WebSocket server               │
│  ├── Spawns agent subprocesses      │
│  ├── Pipes stdio ↔ WebSocket        │
│  └── Sends push when WS disconnects │
└──────────────────┬──────────────────┘
                   │
                   │ stdio (native ACP)
                   │
┌──────────────────▼──────────────────┐
│  Claude Code (or any ACP agent)     │
└─────────────────────────────────────┘
```

---

## UI

### Inbox (home screen)

```
┌─────────────────────────────────────┐
│ Agents                        [+]   │
├─────────────────────────────────────┤
│                                     │
│ 🔴 Login feature      waiting...    │
│ 🟢 API endpoints      step 3/5      │
│ ✅ DB schema          done 5m ago   │
│                                     │
└─────────────────────────────────────┘
```

- Badge = needs attention (approval, error, question)
- Tap → enter session view

### Session view (activity feed)

```
┌─────────────────────────────────────┐
│ ← Login feature             [⏸]    │
├─────────────────────────────────────┤
│                                     │
│ Creating auth middleware...         │
│                                     │
│ 📄 src/auth.ts (writing)            │
│                                     │
│ ┌─────────────────────────────────┐ │
│ │ Run: npm install bcrypt         │ │
│ │                                 │ │
│ │ [Allow]   [Deny]   [Edit]       │ │
│ └─────────────────────────────────┘ │
│                                     │
│ Adding password hashing...          │
│                                     │
├─────────────────────────────────────┤
│ [type to redirect...]        [Send] │
└─────────────────────────────────────┘
```

- Streams `agent_message_chunk` as text
- Shows `tool_call` with file locations (tap to view later)
- `request_permission` → approval card
- Input always visible to redirect

---

## ACP Events → UI Mapping

| ACP Event | UI Element |
|-----------|------------|
| `agent_message_chunk` | Streaming text in feed |
| `tool_call` | Card with icon (read/write/run) |
| `tool_call_update` | Status badge on card |
| `ToolFileLocation` | "📄 path:line" link |
| `plan` | Progress indicator "step X/Y" |
| `request_permission` | Approval card with buttons |

---

## Stack

### Frontend (PWA)

```
React (or Preact)
├── jotai              # atomic state, good for streaming
├── json-rpc-2.0       # ACP message handling
├── reconnecting-ws    # survives app switch
├── llm-ui             # streaming markdown
└── tailwind           # styling
```

### Backend (Sprite)

```
Bun or Node
├── ws                 # WebSocket server
├── child_process      # spawn agents
└── web-push           # notifications when backgrounded
```

---

## Libraries

| Need | Library | Why |
|------|---------|-----|
| JSON-RPC | [json-rpc-2.0](https://npmjs.com/package/json-rpc-2.0) | Bidirectional, TS-first |
| WebSocket | [reconnecting-websocket](https://github.com/joewalnes/reconnecting-websocket) | Auto-reconnect for mobile |
| Streaming MD | [llm-ui](https://llm-ui.com/) | Handles broken syntax mid-stream |
| State | [Jotai](https://jotai.org/) | Atomic, minimal re-renders |
| Push | Service Worker + FCM | Standard PWA pattern |

---

## Multi-Agent

ACP has session IDs. Multiple agents = multiple sessions.

```
sessions: {
  "session_1": { agent: "claude-code", status: "running", ... },
  "session_2": { agent: "goose", status: "waiting", ... },
}
```

Inbox view = list of sessions.
Orchestration (conductor pattern) = future enhancement.

---

## Familiar Metaphors

| If you know... | This is like... |
|----------------|-----------------|
| Email inbox | Sessions needing attention |
| Slack threads | Per-agent conversations |
| GitHub PR | Approval flow |
| Task manager | Session = task with status |

---

## What We're NOT Building (Yet)

- Terminal emulator (xterm.js)
- Code editor (CodeMirror)
- File browser (Chonky)
- Complex orchestration UI

All can be layered on. MVP is inbox + feed + approvals.

---

## Open Questions

1. Auth for the web UI? (Sprite URL is already authed)
2. How to handle multiple Sprites? (future)
3. Diff viewer for file changes? (nice to have)
4. Voice input? (phone-native, interesting)

---

## Next Steps

1. **ACP Bridge**: WebSocket server that spawns Claude Code, pipes messages
2. **Minimal UI**: Inbox + one session view + approval card
3. **Test on phone**: Does it actually feel good?
4. **Iterate**: Add features based on real usage

---

## References

- ACP Spec: https://agentclientprotocol.com/
- ACP GitHub: https://github.com/agentclientprotocol/agent-client-protocol
- Claude Code ACP: Built-in, just run `claude --acp`
- llm-ui: https://llm-ui.com/
- Jotai: https://jotai.org/
- json-rpc-2.0: https://npmjs.com/package/json-rpc-2.0
