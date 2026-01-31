import { WebSocketServer, WebSocket } from "ws";
import { createServer } from "http";
import { AgentConnection } from "./agent.js";
import type { JsonRpcMessage, JsonRpcRequest, BridgeConfig } from "./types.js";
import { join } from "path";
import { existsSync } from "fs";

const config: BridgeConfig = {
  port: parseInt(process.env.PORT || "8080"),
  host: process.env.HOST || "0.0.0.0",
  agentCommand: process.env.AGENT_COMMAND || "npx @zed-industries/claude-code-acp",
  defaultCwd: process.env.DEFAULT_CWD || "/home/sprite",
};

const STATIC_DIR = process.env.STATIC_DIR || join(import.meta.dir, "../../client/dist");
const MAX_BUFFER_SIZE = 1000; // Max messages to buffer per session

// Per-session state - this is the source of truth
interface SessionState {
  agent: AgentConnection;
  agentSessionId: string | null; // The agent's internal session ID
  messageBuffer: Array<{ seq: number; msg: JsonRpcMessage }>; // Buffered messages with sequence numbers
  nextSeq: number;
  currentClient: WebSocket | null; // Currently connected client (if any)
  pendingInit: Map<string | number, (result: unknown) => void>;
  status: "initializing" | "ready" | "error" | "closed";
}

const sessionStates = new Map<string, SessionState>();

// Track pending agent requests (permission requests that need client response)
const pendingAgentRequests = new Map<string | number, { sessionId: string; agent: AgentConnection }>();

function generateSessionId(): string {
  return `session_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

// Buffer a message and optionally send to client
function bufferAndSend(sessionId: string, msg: JsonRpcMessage) {
  const state = sessionStates.get(sessionId);
  if (!state) return;

  const seq = state.nextSeq++;
  const entry = { seq, msg };

  // Add to buffer (with size limit)
  state.messageBuffer.push(entry);
  if (state.messageBuffer.length > MAX_BUFFER_SIZE) {
    state.messageBuffer.shift();
  }

  // Send to client if connected
  if (state.currentClient && state.currentClient.readyState === WebSocket.OPEN) {
    try {
      state.currentClient.send(JSON.stringify({
        ...msg,
        _sessionId: sessionId,
        _seq: seq,
      }));
    } catch (e) {
      console.error(`[send] Failed to send to client:`, e);
      state.currentClient = null;
    }
  }
}

// HTTP server for static files
const server = createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host}`);
  let filePath = join(STATIC_DIR, url.pathname === "/" ? "index.html" : url.pathname);

  if (!existsSync(filePath)) {
    filePath = join(STATIC_DIR, "index.html");
  }

  try {
    const file = Bun.file(filePath);
    if (await file.exists()) {
      const content = await file.arrayBuffer();
      const ext = filePath.split(".").pop();
      const contentType: Record<string, string> = {
        html: "text/html",
        js: "application/javascript",
        css: "text/css",
        svg: "image/svg+xml",
        json: "application/json",
      };
      res.writeHead(200, { "Content-Type": contentType[ext || "html"] || "application/octet-stream" });
      res.end(Buffer.from(content));
    } else {
      res.writeHead(404);
      res.end("Not found");
    }
  } catch {
    res.writeHead(500);
    res.end("Internal error");
  }
});

const wss = new WebSocketServer({ server });

server.listen(config.port, config.host, () => {
  console.log(`ACP Bridge listening on http://${config.host}:${config.port}`);
  console.log(`Serving static files from ${STATIC_DIR}`);
});

wss.on("connection", (ws: WebSocket) => {
  console.log("Client connected");

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
    // Clear currentClient for any sessions this client owned
    for (const [, state] of sessionStates) {
      if (state.currentClient === ws) {
        state.currentClient = null;
      }
    }
  });

  ws.on("error", (err) => {
    console.error("WebSocket error:", err);
  });
});

function handleClientMessage(ws: WebSocket, message: JsonRpcMessage) {
  console.log(`[client] Received:`, JSON.stringify(message).slice(0, 200));

  // Response to pending agent request (permission response)
  if ("id" in message && ("result" in message || "error" in message) && !("method" in message)) {
    const pending = pendingAgentRequests.get(message.id);
    if (pending) {
      console.log(`[bridge] Forwarding client response for request ${message.id}`);
      pendingAgentRequests.delete(message.id);
      pending.agent.send(message);
      return;
    }
  }

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
    case "session/sync":
      handleSessionSync(ws, request);
      break;
    default:
      forwardToAgent(ws, request);
  }
}

async function handleSessionNew(ws: WebSocket, request: JsonRpcRequest) {
  const params = (request.params || {}) as { sessionId?: string; cwd?: string };
  const sessionId = params.sessionId || generateSessionId();
  const cwd = params.cwd || config.defaultCwd;

  if (sessionStates.has(sessionId)) {
    sendError(ws, request.id, -32600, "Session already exists");
    return;
  }

  const pendingInit = new Map<string | number, (result: unknown) => void>();

  const state: SessionState = {
    agent: null as unknown as AgentConnection, // Will be set below
    agentSessionId: null,
    messageBuffer: [],
    nextSeq: 0,
    currentClient: ws,
    pendingInit,
    status: "initializing",
  };

  const agent = new AgentConnection(sessionId, cwd, config.agentCommand, {
    onMessage: (msg) => {
      // Check if this is a response to init requests
      if ("id" in msg && "result" in msg) {
        const handler = pendingInit.get(msg.id);
        if (handler) {
          pendingInit.delete(msg.id);
          handler(msg.result);
          return;
        }
      }

      // Track agent requests that need client response
      if ("method" in msg && "id" in msg) {
        console.log(`[agent] Request from ${sessionId}:`, (msg as JsonRpcRequest).method);
        pendingAgentRequests.set(msg.id, { sessionId, agent });
      }

      // Buffer and send to client
      console.log(`[agent] Message from ${sessionId}:`, JSON.stringify(msg).slice(0, 300));
      bufferAndSend(sessionId, msg);
    },
    onClose: () => {
      console.log(`Agent for session ${sessionId} exited`);
      const state = sessionStates.get(sessionId);
      if (state) {
        state.status = "closed";
        bufferAndSend(sessionId, {
          jsonrpc: "2.0",
          method: "session/closed",
          params: { sessionId },
        });
      }
      // Don't delete state - keep buffer for potential reconnect
    },
  });

  state.agent = agent;
  sessionStates.set(sessionId, state);

  try {
    await agent.start();
    sendResult(ws, request.id, { sessionId, status: "initializing" });
    initializeAgentSession(sessionId);
  } catch (err) {
    console.error("Failed to start agent:", err);
    agent.kill();
    sessionStates.delete(sessionId);
    sendError(ws, request.id, -32603, "Failed to start agent");
  }
}

async function initializeAgentSession(sessionId: string) {
  const state = sessionStates.get(sessionId);
  if (!state) return;

  const { agent, pendingInit } = state;

  try {
    // Step 1: Initialize
    const initPromise = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("init timeout")), 60000);
      pendingInit.set(`init_${sessionId}`, () => {
        clearTimeout(timeout);
        resolve();
      });
    });

    agent.send({
      jsonrpc: "2.0",
      id: `init_${sessionId}`,
      method: "initialize",
      params: { protocolVersion: 1, capabilities: {} },
    });

    await initPromise;

    // Step 2: Create session
    const sessionPromise = new Promise<{ sessionId: string }>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("session timeout")), 60000);
      pendingInit.set(`newsession_${sessionId}`, (result) => {
        clearTimeout(timeout);
        resolve(result as { sessionId: string });
      });
    });

    agent.send({
      jsonrpc: "2.0",
      id: `newsession_${sessionId}`,
      method: "session/new",
      params: { cwd: config.defaultCwd, mcpServers: [] },
    });

    const { sessionId: agentSessionId } = await sessionPromise;
    state.agentSessionId = agentSessionId;
    state.status = "ready";

    console.log(`[init] Session ready: ${sessionId} -> ${agentSessionId}`);

    // Notify via buffer (so it's replayed on reconnect too)
    bufferAndSend(sessionId, {
      jsonrpc: "2.0",
      method: "session/ready",
      params: { sessionId },
    });

  } catch (err) {
    console.error(`Failed to initialize ${sessionId}:`, err);
    state.status = "error";
    agent.kill();

    bufferAndSend(sessionId, {
      jsonrpc: "2.0",
      method: "session/error",
      params: { sessionId, error: "Initialization failed" },
    });
  }
}

async function handleSessionPrompt(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; prompt?: unknown };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const state = sessionStates.get(params.sessionId);
  if (!state) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  // Claim this session for the requesting client
  state.currentClient = ws;

  // Wait for initialization if needed
  if (!state.agentSessionId) {
    for (let i = 0; i < 120 && !state.agentSessionId && state.status === "initializing"; i++) {
      await new Promise(r => setTimeout(r, 500));
    }
    if (!state.agentSessionId) {
      sendError(ws, request.id, -32602, "Session not ready");
      return;
    }
  }

  state.agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/prompt",
    params: { sessionId: state.agentSessionId, prompt: params.prompt },
  });
}

function handleSessionCancel(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string };
  const state = sessionStates.get(params?.sessionId);

  if (!state?.agentSessionId) {
    sendError(ws, request.id, -32602, "Session not found or not ready");
    return;
  }

  state.agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/cancel",
    params: { sessionId: state.agentSessionId },
  });
}

function handleSessionList(ws: WebSocket, request: JsonRpcRequest) {
  const sessions = Array.from(sessionStates.entries()).map(([id, state]) => ({
    id,
    status: state.status,
    bufferedMessages: state.messageBuffer.length,
    lastSeq: state.nextSeq - 1,
  }));

  sendResult(ws, request.id, { sessions });
}

// Sync: replay buffered messages since lastSeq
function handleSessionSync(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; lastSeq?: number };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const state = sessionStates.get(params.sessionId);
  if (!state) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  // Claim this session
  state.currentClient = ws;

  const lastSeq = params.lastSeq ?? -1;
  const messages = state.messageBuffer
    .filter(entry => entry.seq > lastSeq)
    .map(entry => ({
      ...entry.msg,
      _sessionId: params.sessionId,
      _seq: entry.seq,
    }));

  console.log(`[sync] Session ${params.sessionId}: replaying ${messages.length} messages since seq ${lastSeq}`);

  sendResult(ws, request.id, {
    sessionId: params.sessionId,
    status: state.status,
    messages,
    currentSeq: state.nextSeq - 1,
  });
}

function forwardToAgent(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId?: string } | undefined;
  const state = sessionStates.get(params?.sessionId || "");

  if (!state) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  state.agent.send(request);
}

function sendResult(ws: WebSocket, id: string | number | null, result: unknown) {
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
}

function sendError(ws: WebSocket, id: string | number | null, code: number, message: string) {
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }));
}
