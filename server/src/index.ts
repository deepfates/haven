import { WebSocketServer, WebSocket } from "ws";
import { AgentConnection } from "./agent.js";
import type { JsonRpcMessage, JsonRpcRequest, BridgeConfig } from "./types.js";

const config: BridgeConfig = {
  port: parseInt(process.env.PORT || "3000"),
  host: process.env.HOST || "0.0.0.0",
  agentCommand: process.env.AGENT_COMMAND || "claude",
  defaultCwd: process.env.DEFAULT_CWD || process.cwd(),
};

// Session management
const sessions = new Map<string, AgentConnection>();
const clientSessions = new Map<WebSocket, Set<string>>();

function generateSessionId(): string {
  return `session_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

// WebSocket server
const wss = new WebSocketServer({ port: config.port, host: config.host });

console.log(`ACP Bridge listening on ws://${config.host}:${config.port}`);

wss.on("connection", (ws: WebSocket) => {
  console.log("Client connected");
  clientSessions.set(ws, new Set());

  ws.on("message", (data: Buffer) => {
    try {
      const message = JSON.parse(data.toString()) as JsonRpcMessage;
      handleClientMessage(ws, message);
    } catch (err) {
      console.error("Failed to parse client message:", err);
      sendError(ws, null, -32700, "Parse error");
    }
  });

  ws.on("close", () => {
    console.log("Client disconnected");
    // Clean up sessions owned by this client
    const ownedSessions = clientSessions.get(ws);
    if (ownedSessions) {
      for (const sessionId of ownedSessions) {
        const agent = sessions.get(sessionId);
        if (agent) {
          agent.kill();
          sessions.delete(sessionId);
        }
      }
    }
    clientSessions.delete(ws);
  });

  ws.on("error", (err) => {
    console.error("WebSocket error:", err);
  });
});

function handleClientMessage(ws: WebSocket, message: JsonRpcMessage) {
  // Only handle requests (not responses or notifications from client)
  if (!("method" in message) || !("id" in message)) {
    return;
  }

  const request = message as JsonRpcRequest;

  switch (request.method) {
    case "session/new":
      handleSessionNew(ws, request);
      break;
    case "session/prompt":
      handleSessionPrompt(ws, request);
      break;
    case "session/cancel":
      handleSessionCancel(ws, request);
      break;
    case "session/list":
      handleSessionList(ws, request);
      break;
    default:
      // Forward other methods to the agent
      forwardToAgent(ws, request);
  }
}

async function handleSessionNew(ws: WebSocket, request: JsonRpcRequest) {
  const params = (request.params || {}) as { sessionId?: string; cwd?: string };
  const sessionId = params.sessionId || generateSessionId();
  const cwd = params.cwd || config.defaultCwd;

  if (sessions.has(sessionId)) {
    sendError(ws, request.id, -32600, "Session already exists");
    return;
  }

  const agent = new AgentConnection(sessionId, cwd, config.agentCommand, {
    onMessage: (msg) => {
      // Forward agent messages to client, tagged with session
      ws.send(JSON.stringify({
        ...msg,
        _sessionId: sessionId,
      }));
    },
    onClose: () => {
      console.log(`Agent for session ${sessionId} exited`);
      sessions.delete(sessionId);
      clientSessions.get(ws)?.delete(sessionId);

      // Notify client
      ws.send(JSON.stringify({
        jsonrpc: "2.0",
        method: "session/closed",
        params: { sessionId },
      }));
    },
  });

  try {
    await agent.start();
    sessions.set(sessionId, agent);
    clientSessions.get(ws)?.add(sessionId);

    // Send initialize to agent
    agent.send({
      jsonrpc: "2.0",
      id: `init_${sessionId}`,
      method: "initialize",
      params: { protocolVersion: 1, capabilities: {} },
    });

    sendResult(ws, request.id, { sessionId });
  } catch (err) {
    console.error("Failed to start agent:", err);
    sendError(ws, request.id, -32603, "Failed to start agent");
  }
}

function handleSessionPrompt(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; content: unknown };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const agent = sessions.get(params.sessionId);
  if (!agent) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  // Forward to agent
  agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/prompt",
    params: { content: params.content },
  });
}

function handleSessionCancel(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const agent = sessions.get(params.sessionId);
  if (!agent) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/cancel",
    params: {},
  });
}

function handleSessionList(ws: WebSocket, request: JsonRpcRequest) {
  const ownedSessions = clientSessions.get(ws) || new Set();
  const sessionList = Array.from(ownedSessions).map((id) => ({
    id,
    running: sessions.get(id)?.isRunning || false,
  }));

  sendResult(ws, request.id, { sessions: sessionList });
}

function forwardToAgent(ws: WebSocket, request: JsonRpcRequest) {
  // Try to extract sessionId from params
  const params = request.params as { sessionId?: string } | undefined;
  const sessionId = params?.sessionId;

  if (!sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const agent = sessions.get(sessionId);
  if (!agent) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  agent.send(request);
}

function sendResult(ws: WebSocket, id: string | number | null, result: unknown) {
  ws.send(JSON.stringify({
    jsonrpc: "2.0",
    id,
    result,
  }));
}

function sendError(ws: WebSocket, id: string | number | null, code: number, message: string) {
  ws.send(JSON.stringify({
    jsonrpc: "2.0",
    id,
    error: { code, message },
  }));
}
