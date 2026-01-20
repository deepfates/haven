import { WebSocketServer, WebSocket } from "ws";
import { createServer } from "http";
import { AgentConnection } from "./agent.js";
import type { JsonRpcMessage, JsonRpcRequest, BridgeConfig } from "./types.js";
import { join } from "path";
import { existsSync } from "fs";

const config: BridgeConfig = {
  port: parseInt(process.env.PORT || "8080"),
  host: process.env.HOST || "0.0.0.0",
  // Use the Zed ACP adapter for Claude Code
  agentCommand: process.env.AGENT_COMMAND || "npx @zed-industries/claude-code-acp",
  defaultCwd: process.env.DEFAULT_CWD || "/home/sprite",
};

const STATIC_DIR = process.env.STATIC_DIR || join(import.meta.dir, "../../client/dist");

// Session management
const sessions = new Map<string, AgentConnection>();
const clientSessions = new Map<WebSocket, Set<string>>();

function generateSessionId(): string {
  return `session_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

// HTTP server for static files
const server = createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host}`);
  let filePath = join(STATIC_DIR, url.pathname === "/" ? "index.html" : url.pathname);

  // If file doesn't exist, serve index.html for client-side routing
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

// WebSocket server attached to HTTP server
const wss = new WebSocketServer({ server });

server.listen(config.port, config.host, () => {
  console.log(`ACP Bridge listening on http://${config.host}:${config.port}`);
  console.log(`Serving static files from ${STATIC_DIR}`);
});

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

// Map bridge sessionId to agent's internal sessionId
const sessionIdMap = new Map<string, string>();
// Track pending init handlers per session
const pendingInitHandlers = new Map<string, Map<string | number, (result: unknown) => void>>();

async function handleSessionNew(ws: WebSocket, request: JsonRpcRequest) {
  const params = (request.params || {}) as { sessionId?: string; cwd?: string };
  const bridgeSessionId = params.sessionId || generateSessionId();
  const cwd = params.cwd || config.defaultCwd;

  if (sessions.has(bridgeSessionId)) {
    sendError(ws, request.id, -32600, "Session already exists");
    return;
  }

  // Track pending init responses for this session
  const pendingInit = new Map<string | number, (result: unknown) => void>();
  pendingInitHandlers.set(bridgeSessionId, pendingInit);

  const agent = new AgentConnection(bridgeSessionId, cwd, config.agentCommand, {
    onMessage: (msg) => {
      // Check if this is a response to one of our init requests
      if ("id" in msg && "result" in msg) {
        const handler = pendingInit.get(msg.id);
        if (handler) {
          pendingInit.delete(msg.id);
          handler(msg.result);
          return;
        }
      }

      // Forward agent messages to client, tagged with bridge sessionId
      try {
        ws.send(JSON.stringify({
          ...msg,
          _sessionId: bridgeSessionId,
        }));
      } catch (e) {
        console.error(`Failed to send to client for ${bridgeSessionId}:`, e);
      }
    },
    onClose: () => {
      console.log(`Agent for session ${bridgeSessionId} exited`);
      sessions.delete(bridgeSessionId);
      sessionIdMap.delete(bridgeSessionId);
      pendingInitHandlers.delete(bridgeSessionId);
      clientSessions.get(ws)?.delete(bridgeSessionId);

      // Notify client
      try {
        ws.send(JSON.stringify({
          jsonrpc: "2.0",
          method: "session/closed",
          params: { sessionId: bridgeSessionId },
        }));
      } catch (e) {
        // Client already disconnected
      }
    },
  });

  try {
    await agent.start();
    sessions.set(bridgeSessionId, agent);
    clientSessions.get(ws)?.add(bridgeSessionId);

    // Return sessionId immediately - agent initializes in background
    sendResult(ws, request.id, { sessionId: bridgeSessionId, status: "initializing" });

    // Initialize agent in background
    initializeAgentSession(bridgeSessionId, agent, pendingInit, cwd, ws);
  } catch (err) {
    console.error("Failed to start agent:", err);
    agent.kill();
    sessions.delete(bridgeSessionId);
    pendingInitHandlers.delete(bridgeSessionId);
    sendError(ws, request.id, -32603, "Failed to start agent");
  }
}

async function initializeAgentSession(
  bridgeSessionId: string,
  agent: AgentConnection,
  pendingInit: Map<string | number, (result: unknown) => void>,
  cwd: string,
  ws: WebSocket
) {
  try {
    // Step 1: Initialize the agent
    const initPromise = new Promise<void>((resolve, reject) => {
      const timeoutId = setTimeout(() => reject(new Error("initialize timeout")), 60000);
      pendingInit.set(`init_${bridgeSessionId}`, () => {
        clearTimeout(timeoutId);
        resolve();
      });
    });

    agent.send({
      jsonrpc: "2.0",
      id: `init_${bridgeSessionId}`,
      method: "initialize",
      params: { protocolVersion: 1, capabilities: {} },
    });

    await initPromise;
    console.log(`Agent initialized for ${bridgeSessionId}`);

    // Step 2: Create a session in the agent to get its sessionId
    const newSessionPromise = new Promise<{ sessionId: string }>((resolve, reject) => {
      const timeoutId = setTimeout(() => reject(new Error("session/new timeout")), 60000);
      pendingInit.set(`newsession_${bridgeSessionId}`, (result) => {
        clearTimeout(timeoutId);
        resolve(result as { sessionId: string });
      });
    });

    agent.send({
      jsonrpc: "2.0",
      id: `newsession_${bridgeSessionId}`,
      method: "session/new",
      params: { cwd, mcpServers: [] },
    });

    const { sessionId: agentSessionId } = await newSessionPromise;
    sessionIdMap.set(bridgeSessionId, agentSessionId);
    console.log(`Session mapped: ${bridgeSessionId} -> ${agentSessionId}`);

    // Notify client that session is ready
    try {
      ws.send(JSON.stringify({
        jsonrpc: "2.0",
        method: "session/ready",
        params: { sessionId: bridgeSessionId },
      }));
    } catch (e) {
      // Client disconnected
    }
  } catch (err) {
    console.error(`Failed to initialize agent for ${bridgeSessionId}:`, err);
    agent.kill();
    sessions.delete(bridgeSessionId);
    sessionIdMap.delete(bridgeSessionId);
    pendingInitHandlers.delete(bridgeSessionId);

    // Notify client of failure
    try {
      ws.send(JSON.stringify({
        jsonrpc: "2.0",
        method: "session/error",
        params: { sessionId: bridgeSessionId, error: "Agent initialization failed" },
      }));
    } catch (e) {
      // Client disconnected
    }
  }
}

async function handleSessionPrompt(ws: WebSocket, request: JsonRpcRequest) {
  const params = request.params as { sessionId: string; content?: unknown; prompt?: unknown };
  if (!params?.sessionId) {
    sendError(ws, request.id, -32602, "Missing sessionId");
    return;
  }

  const agent = sessions.get(params.sessionId);
  if (!agent) {
    sendError(ws, request.id, -32602, "Session not found");
    return;
  }

  // Wait for agent to be initialized (with timeout)
  let agentSessionId = sessionIdMap.get(params.sessionId);
  if (!agentSessionId) {
    // Wait up to 60s for initialization
    for (let i = 0; i < 120; i++) {
      await new Promise((r) => setTimeout(r, 500));
      agentSessionId = sessionIdMap.get(params.sessionId);
      if (agentSessionId) break;
      // Check if session still exists
      if (!sessions.has(params.sessionId)) {
        sendError(ws, request.id, -32602, "Session initialization failed");
        return;
      }
    }
    if (!agentSessionId) {
      sendError(ws, request.id, -32602, "Session initialization timeout");
      return;
    }
  }

  // ACP expects "prompt" array, not "content" - support both for compatibility
  const prompt = params.prompt || params.content;

  // Forward to agent with agent's internal sessionId
  agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/prompt",
    params: { sessionId: agentSessionId, prompt },
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

  // Get the agent's internal sessionId
  const agentSessionId = sessionIdMap.get(params.sessionId);
  if (!agentSessionId) {
    sendError(ws, request.id, -32602, "Session not initialized");
    return;
  }

  agent.send({
    jsonrpc: "2.0",
    id: request.id,
    method: "session/cancel",
    params: { sessionId: agentSessionId },
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
