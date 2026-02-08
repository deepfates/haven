import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { WebSocket } from "ws";
import { createServer as createNetServer } from "net";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

let PORT = Number(process.env.ACP_TEST_PORT || 0);
let WS_URL = "";
const ROOT_CWD = process.cwd();
const DEFAULT_SERVER_CWD = join(ROOT_CWD, "server");
const SERVER_CWD = process.env.ACP_SERVER_CWD || (existsSync(DEFAULT_SERVER_CWD) ? DEFAULT_SERVER_CWD : ROOT_CWD);
const TEST_CWD = process.env.ACP_TEST_CWD || ROOT_CWD;

let serverProcess: ReturnType<typeof Bun.spawn> | null = null;
let staticDir: string | null = null;
let testHome: string | null = null;

async function getFreePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const srv = createNetServer();
    srv.listen(0, "127.0.0.1", () => {
      const address = srv.address();
      if (address && typeof address === "object") {
        const port = address.port;
        srv.close(() => resolve(port));
      } else {
        srv.close();
        reject(new Error("Failed to acquire port"));
      }
    });
    srv.on("error", reject);
  });
}

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
function waitForOpen(ws: WebSocket, timeoutMs = 5000): Promise<void> {
  return new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.OPEN) {
      resolve();
      return;
    }
    const timeout = setTimeout(() => reject(new Error("WebSocket open timeout")), timeoutMs);
    ws.once("open", () => {
      clearTimeout(timeout);
      resolve();
    });
    ws.once("error", (err) => {
      clearTimeout(timeout);
      reject(err);
    });
  });
}

describe("ACP Bridge Server", () => {
  beforeAll(async () => {
    if (!PORT) {
      PORT = await getFreePort();
    }
    WS_URL = `ws://localhost:${PORT}/ws`;

    // Create temp static dir and home to isolate DB
    staticDir = mkdtempSync(join(tmpdir(), "acp-client-static-"));
    writeFileSync(join(staticDir, "index.html"), "<!doctype html><html><body>OK</body></html>");

    testHome = mkdtempSync(join(tmpdir(), "acp-client-home-"));

    // Start server on test port
    serverProcess = Bun.spawn(["bun", "run", "src/index.ts"], {
      cwd: SERVER_CWD,
      env: {
        ...process.env,
        PORT: String(PORT),
        STATIC_DIR: staticDir,
        HOME: testHome,
        AGENT_COMMAND: process.env.ACP_TEST_AGENT_COMMAND || "/usr/bin/true",
      },
      stdout: "pipe",
      stderr: "pipe",
    });

    // Wait for server to start
    await new Promise((resolve) => setTimeout(resolve, 1000));
  });

  afterAll(() => {
    serverProcess?.kill();
    if (staticDir) {
      rmSync(staticDir, { recursive: true, force: true });
    }
    if (testHome) {
      rmSync(testHome, { recursive: true, force: true });
    }
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
      const response = await sendRequest(ws, "session/new", { cwd: TEST_CWD });
      expect(response.result).toBeDefined();
      expect((response.result as { sessionId: string }).sessionId).toMatch(/^session_/);
    });

    test("session/prompt fails without sessionId", async () => {
      const response = await sendRequest(ws, "session/prompt", { prompt: [{ type: "text", text: "hello" }] });
      expect(response.error).toBeDefined();
    });

    test("session/prompt fails with invalid sessionId", async () => {
      const response = await sendRequest(ws, "session/prompt", {
        sessionId: "nonexistent",
        prompt: [{ type: "text", text: "hello" }],
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
