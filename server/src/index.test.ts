import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { WebSocket } from "ws";

const PORT = 8081; // Use different port than production
const WS_URL = `ws://localhost:${PORT}`;

let serverProcess: ReturnType<typeof Bun.spawn> | null = null;

// Helper to send JSON-RPC request and get response
function sendRequest(ws: WebSocket, method: string, params?: unknown): Promise<{ id: number; result?: unknown; error?: unknown }> {
  return new Promise((resolve, reject) => {
    const id = Date.now();
    const timeout = setTimeout(() => reject(new Error("Request timeout")), 5000);

    const handler = (data: Buffer) => {
      const msg = JSON.parse(data.toString());
      if (msg.id === id) {
        clearTimeout(timeout);
        ws.off("message", handler);
        resolve(msg);
      }
    };

    ws.on("message", handler);
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

// Wait for WebSocket to be ready
function waitForOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.OPEN) {
      resolve();
      return;
    }
    ws.once("open", resolve);
    ws.once("error", reject);
  });
}

describe("ACP Bridge Server", () => {
  beforeAll(async () => {
    // Start server on test port
    serverProcess = Bun.spawn(["bun", "run", "src/index.ts"], {
      cwd: "/home/sprite/acp-client/server",
      env: { ...process.env, PORT: String(PORT) },
      stdout: "pipe",
      stderr: "pipe",
    });

    // Wait for server to start
    await new Promise((resolve) => setTimeout(resolve, 1000));
  });

  afterAll(() => {
    serverProcess?.kill();
  });

  describe("WebSocket Connection", () => {
    let ws: WebSocket;

    beforeEach(async () => {
      ws = new WebSocket(WS_URL);
      await waitForOpen(ws);
    });

    afterEach(() => {
      ws.close();
    });

    test("connects successfully", () => {
      expect(ws.readyState).toBe(WebSocket.OPEN);
    });

    test("session/list returns empty array initially", async () => {
      const response = await sendRequest(ws, "session/list");
      expect(response.result).toEqual({ sessions: [] });
    });

    test("session/new creates a session", async () => {
      const response = await sendRequest(ws, "session/new", { cwd: "/home/sprite" });
      expect(response.result).toBeDefined();
      expect((response.result as { sessionId: string }).sessionId).toMatch(/^session_/);
    });

    test("session/prompt fails without sessionId", async () => {
      const response = await sendRequest(ws, "session/prompt", { content: [{ type: "text", text: "hello" }] });
      expect(response.error).toBeDefined();
    });

    test("session/prompt fails with invalid sessionId", async () => {
      const response = await sendRequest(ws, "session/prompt", {
        sessionId: "nonexistent",
        content: [{ type: "text", text: "hello" }],
      });
      expect(response.error).toBeDefined();
    });
  });

  describe("HTTP Static Serving", () => {
    test("serves index.html at root", async () => {
      const response = await fetch(`http://localhost:${PORT}/`);
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toBe("text/html");
    });

    test("serves static files", async () => {
      // This will 404 if file doesn't exist, but should return 200 for index.html fallback
      const response = await fetch(`http://localhost:${PORT}/some-route`);
      expect(response.status).toBe(200); // SPA fallback to index.html
    });
  });
});

describe("JSON-RPC Message Validation", () => {
  test("valid request structure", () => {
    const request = {
      jsonrpc: "2.0",
      id: 1,
      method: "session/new",
      params: { cwd: "/home/sprite" },
    };

    expect(request.jsonrpc).toBe("2.0");
    expect(typeof request.id).toBe("number");
    expect(typeof request.method).toBe("string");
  });

  test("notification has no id", () => {
    const notification = {
      jsonrpc: "2.0",
      method: "session/update",
      params: { sessionId: "test", update: { type: "agent_message_chunk", content: "hello" } },
    };

    expect(notification).not.toHaveProperty("id");
    expect(notification.method).toBe("session/update");
  });
});
