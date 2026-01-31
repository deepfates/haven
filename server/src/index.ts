import { WebSocketServer, WebSocket } from "ws";
import { createServer } from "http";
import { AgentConnection } from "./agent.js";
import { sessions, updates, pendingRequests } from "./db.js";
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

// Runtime state (not persisted - rebuilt on restart)
interface AgentProcess {
  agent: AgentConnection;
  pendingInit: Map<string | number, (result: unknown) => void>;
}

const agentProcesses = new Map<string, AgentProcess>();

// Track connected clients per session for push notifications
const sessionClients = new Map<string, Set<WebSocket>>();

// Track pending agent requests (permission requests that need client response)
const pendingAgentRequests = new Map<string | number, { sessionId: string; agent: AgentConnection }>();

function generateSessionId(): string {
  return `session_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

// Push an update to all clients watching a session
function pushToClients(sessionId: string, message: object) {
  const clients = sessionClients.get(sessionId);
  if (!clients) return;

  const data = JSON.stringify(message);
  for (const client of clients) {
    if (client.readyState === WebSocket.OPEN) {
      try {
        client.send(data);
      } catch (e) {
        console.error(`[push] Failed to send to client:`, e);
        clients.delete(client);
      }
    } else {
      clients.delete(client);
    }
  }
}

// Store update and push to clients
function persistAndPush(sessionId: string, updateType: string, payload: object) {
  const seq = updates.getLastSeq(sessionId) + 1;
  updates.add(sessionId, seq, updateType, payload);

  // Update session timestamp
  const session = sessions.get(sessionId);
  if (session) {
    sessions.setStatus(sessionId, session.status); // This updates updated_at
  }

  pushToClients(sessionId, {
    jsonrpc: "2.0",
    method: "session/updated",
    params: {
      sessionId,
      updates: [{ seq, updateType, payload }],
    },
  });
}

// HTTP server for static files (production mode)
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

// Don't auto-attach to server - we'll handle upgrades manually
const wss = new WebSocketServer({ noServer: true });

// Handle WebSocket upgrades on /ws path
server.on("upgrade", (req, socket, head) => {
  const url = req.url || "";

  if (url.startsWith("/ws")) {
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  } else {
    socket.destroy();
  }
});

server.listen(config.port, config.host, () => {
  console.log(`ACP Bridge listening on http://${config.host}:${config.port}`);
  console.log(`Serving static files from ${STATIC_DIR}`);
  console.log(`Database: ~/.acp-client/sessions.db`);
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
    // Remove from all session client lists
    for (const [, clients] of sessionClients) {
      clients.delete(ws);
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
      console.log(`[service] Forwarding client response for request ${message.id}`);
      pendingAgentRequests.delete(message.id);

      // Delete from DB
      pendingRequests.delete(pending.sessionId, String(message.id));

      pending.agent.send(message);
      return;
    }
  }

  if (!("method" in message) || !("id" in message)) {
    return;
  }

  const request = message as JsonRpcRequest;

  switch (request.method) {
    case "session/list":
      handleSessionList(ws, request);
      break;
    case "session/new":
      handleSessionNew(ws, request);
      break;
    case "session/get":
      handleSessionGet(ws, request);
      break;
    case "session/prompt":
      handleSessionPrompt(ws, request);
      break;
    case "session/respond":
      handleSessionRespond(ws, request);
      break;
    case "session/cancel":
      handleSessionCancel(ws, request);
      break;
    case "session/archive":
      handleSessionArchive(ws, request);
      break;
    // Legacy endpoints for backwards compat
    case "session/sync":
      handleSessionGet(ws, request);
      break;
    default:
      sendError(ws, request.id, -32601, `Unknown method: ${request.method}`);
  }
}

// List sessions
function handleSessionList(ws: WebSocket, request: JsonRpcRequest) {
  const params = (request.params || {}) as { archived?: boolean; status?: string[] };
  const sessionList = sessions.list(params.archived || false, params.status);

  sendResult(ws, request.id, {
    sessions: sessionList.map(s => ({
      id: s.id,
      agentType: s.agent_type,
      cwd: s.cwd,
      title: s.title,
      status: s.status,
      exitReason: s.exit_reason,
      createdAt: s.created_at,
      updatedAt: s.updated_at,
    })),
  });
}

// Create new session
async function handleSessionNew(ws: WebSocket, request: JsonRpcRequest) {
  const params = (request.params || {}) as { agentType?: string; cwd?: string; title?: string };
  const sessionId = generateSessionId();
  const agentType = params.agentType || "claude-code-acp";
  const cwd = params.cwd || config.defaultCwd;
  const title = params.title || `Session ${new Date().toLocaleString()}`;

  // Create in DB
  sessions.create(sessionId, agentType, cwd, title);

  // Subscribe this client to updates
  if (!sessionClients.has(sessionId)) {
    sessionClients.set(sessionId, new Set());
  }
  sessionClients.get(sessionId)!.add(ws);

  // Start agent process
  const pendingInit = new Map<string | number, (result: unknown) => void>();

  const agent = new AgentConnection(sessionId, cwd, config.agentCommand, {
    onMessage: (msg) => handleAgentMessage(sessionId, msg, pendingInit),
    onClose: () => handleAgentClose(sessionId),
  });

  agentProcesses.set(sessionId, { agent, pendingInit });

  try {
    await agent.start();
    sendResult(ws, request.id, { sessionId });
    initializeAgentSession(sessionId, cwd);
  } catch (err) {
    console.error("Failed to start agent:", err);
    agent.kill();
    agentProcesses.delete(sessionId);
    sessions.setStatus(sessionId, "error");
    sendError(ws, request.id, -32603, "Failed to start agent");
  }
}

// Handle messages from agent
function handleAgentMessage(
  sessionId: string,
  msg: JsonRpcMessage,
  pendingInit: Map<string | number, (result: unknown) => void>
) {
  // Check if this is a response to init requests
  if ("id" in msg && "result" in msg) {
    const handler = pendingInit.get(msg.id);
    if (handler) {
      pendingInit.delete(msg.id);
      handler(msg.result);
      return;
    }
  }

  // Agent request (e.g., permission request)
  if ("method" in msg && "id" in msg) {
    const request = msg as JsonRpcRequest;
    console.log(`[agent] Request from ${sessionId}:`, request.method, JSON.stringify(request).slice(0, 500));

    const proc = agentProcesses.get(sessionId);
    if (proc) {
      pendingAgentRequests.set(msg.id, { sessionId, agent: proc.agent });
    }

    // Store pending request in DB
    if (request.method === "session/request_permission") {
      pendingRequests.add(
        `${sessionId}_${msg.id}`,
        sessionId,
        String(msg.id),
        "permission",
        request.params as object
      );

      sessions.setStatus(sessionId, "waiting");
    }

    // Push to clients
    pushToClients(sessionId, {
      jsonrpc: "2.0",
      method: "session/request",
      params: { sessionId, requestId: msg.id, request: request.params },
    });
    return;
  }

  // Notification (session update)
  if ("method" in msg && !("id" in msg)) {
    const notification = msg as { method: string; params?: unknown };

    if (notification.method === "session/update" && notification.params) {
      const params = notification.params as { update?: { sessionUpdate?: string } };
      const updateType = params.update?.sessionUpdate || "unknown";

      // Persist and push
      persistAndPush(sessionId, updateType, params.update as object);
    }
  }
}

// Handle agent process exit
function handleAgentClose(sessionId: string) {
  console.log(`Agent for session ${sessionId} exited`);

  const session = sessions.get(sessionId);
  if (session && session.status !== "completed" && session.status !== "error") {
    sessions.setExited(sessionId, "process_exit");
  }

  agentProcesses.delete(sessionId);

  pushToClients(sessionId, {
    jsonrpc: "2.0",
    method: "session/status_changed",
    params: { sessionId, status: "exited", exitReason: "process_exit" },
  });
}

// Initialize agent session (ACP handshake)
async function initializeAgentSession(sessionId: string, cwd: string) {
  const proc = agentProcesses.get(sessionId);
  if (!proc) return;

  const { agent, pendingInit } = proc;

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

    // Step 2: Create session with agent
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
      params: { cwd, mcpServers: [] },
    });

    const { sessionId: agentSessionId } = await sessionPromise;

    // Update DB
    sessions.setAgentSessionId(sessionId, agentSessionId);
    sessions.setStatus(sessionId, "running");

    console.log(`[init] Session ready: ${sessionId} -> ${agentSessionId}`);

    pushToClients(sessionId, {
      jsonrpc: "2.0",
      method: "session/status_changed",
      params: { sessionId, status: "running" },
    });

  } catch (err) {
    console.error(`Failed to initialize ${sessionId}:`, err);
    sessions.setStatus(sessionId, "error");
    agent.kill();
    agentProcesses.delete(sessionId);

    pushToClients(sessionId, {
      jsonrpc: "2.0",
      method: "session/status_changed",
      params: { sessionId, status: "error" },
    });
  }
}

// Get session with updates
function handleSessionGet(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; since?: number };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const session = sessions.get(params.sessionId);
  if (!session) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  // Subscribe client to this session
  if (!sessionClients.has(params.sessionId)) {
    sessionClients.set(params.sessionId, new Set());
  }
  sessionClients.get(params.sessionId)!.add(ws);

  // Get updates
  const since = params.since ?? 0;
  const updateList = since > 0
    ? updates.listSince(params.sessionId, since)
    : updates.list(params.sessionId);

  // Get pending requests
  const pending = pendingRequests.listForSession(params.sessionId);

  sendResult(ws, request.id, {
    session: {
      id: session.id,
      agentType: session.agent_type,
      cwd: session.cwd,
      title: session.title,
      status: session.status,
      exitReason: session.exit_reason,
      createdAt: session.created_at,
      updatedAt: session.updated_at,
    },
    updates: updateList.map(u => ({
      seq: u.seq,
      updateType: u.update_type,
      payload: JSON.parse(u.payload),
      createdAt: u.created_at,
    })),
    pendingRequests: pending.map(p => ({
      requestId: p.request_id,
      requestType: p.request_type,
      payload: JSON.parse(p.payload),
    })),
  });
}

// Send prompt to agent
async function handleSessionPrompt(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; prompt: unknown };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const session = sessions.get(params.sessionId);
  if (!session) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  // Subscribe client
  if (!sessionClients.has(params.sessionId)) {
    sessionClients.set(params.sessionId, new Set());
  }
  sessionClients.get(params.sessionId)!.add(ws);

  // Check if agent is running
  let proc = agentProcesses.get(params.sessionId);

  // If agent died but session exists, try to resume
  if (!proc && session.agent_session_id) {
    // TODO: Implement agent restart/resume
    sendError(ws, request.id, -32602, "Agent not running. Session resume not yet implemented.");
    return;
  }

  if (!proc) {
    sendError(ws, request.id, -32602, "Agent not ready");
    return;
  }

  // Wait for initialization if needed
  if (!session.agent_session_id) {
    for (let i = 0; i < 120; i++) {
      await new Promise(r => setTimeout(r, 500));
      const updated = sessions.get(params.sessionId);
      if (updated?.agent_session_id) break;
      if (updated?.status === "error") {
        sendError(ws, request.id, -32602, "Session initialization failed");
        return;
      }
    }
  }

  const updated = sessions.get(params.sessionId);
  if (!updated?.agent_session_id) {
    sendError(ws, request.id, -32602, "Session not ready");
    return;
  }

  // Store user message as an update
  // prompt is an array like [{type: "text", text: "..."}]
  const promptArray = params.prompt as Array<{ type: string; text?: string }>;
  const promptText = promptArray?.[0]?.text || JSON.stringify(params.prompt);
  persistAndPush(params.sessionId, "user_message", {
    sessionUpdate: "user_message_chunk",
    content: { type: "text", text: promptText },
  });

  sessions.setStatus(params.sessionId, "running");

  // Forward to agent
  proc.agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/prompt",
    params: { sessionId: updated.agent_session_id, prompt: params.prompt },
  });

  // Response will come back through agent message handler
  sendResult(ws, request.id, { success: true });
}

// Respond to agent request
function handleSessionRespond(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; requestId: string; response: object };
  if (!params?.sessionId || !params?.requestId) {
    sendError(ws, request.id, -32602, "Missing sessionId or requestId");
    return;
  }

  const proc = agentProcesses.get(params.sessionId);
  if (!proc) {
    sendError(ws, request.id, -32602, "Agent not running");
    return;
  }

  // Convert requestId back to number if it was originally a number
  // (JSON-RPC allows both string and number IDs, agent uses numbers)
  const originalId = /^\d+$/.test(params.requestId) ? parseInt(params.requestId, 10) : params.requestId;

  // Forward response to agent
  proc.agent.send({
    jsonrpc: "2.0",
    id: originalId,
    result: params.response,
  });

  // Clean up
  pendingAgentRequests.delete(params.requestId);
  pendingRequests.delete(params.sessionId, params.requestId);
  sessions.setStatus(params.sessionId, "running");

  sendResult(ws, request.id, { success: true });
}

// Cancel session
function handleSessionCancel(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const session = sessions.get(params.sessionId);
  if (!session) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  const proc = agentProcesses.get(params.sessionId);
  if (proc && session.agent_session_id) {
    proc.agent.send({
      jsonrpc: "2.0",
      method: "session/cancel",
      params: { sessionId: session.agent_session_id },
    });
  }

  sessions.setStatus(params.sessionId, "completed");

  sendResult(ws, request.id, { success: true });
}

// Archive session
function handleSessionArchive(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  sessions.archive(params.sessionId);

  // Kill agent if running
  const proc = agentProcesses.get(params.sessionId);
  if (proc) {
    proc.agent.kill();
    agentProcesses.delete(params.sessionId);
  }

  sendResult(ws, request.id, { success: true });
}

function sendResult(ws: WebSocket, id: string | number | null, result: unknown) {
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
}

function sendError(ws: WebSocket, id: string | number | null, code: number, message: string) {
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }));
}
