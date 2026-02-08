/**
 * Red-green TDD tests for identified bugs.
 *
 * These tests use the advanced agent stub so we can exercise prompt/response,
 * permission, cancel and crash flows.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { WebSocket } from "ws";
import { createServer as createNetServer } from "net";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const ROOT_CWD = process.cwd();
const DEFAULT_SERVER_CWD = join(ROOT_CWD, "server");
const SERVER_CWD =
  process.env.ACP_SERVER_CWD ||
  (existsSync(DEFAULT_SERVER_CWD) ? DEFAULT_SERVER_CWD : ROOT_CWD);
// Repo root: if we're running from server/, go up one level
const REPO_ROOT = existsSync(join(ROOT_CWD, "e2e"))
  ? ROOT_CWD
  : join(ROOT_CWD, "..");
const STUB = join(REPO_ROOT, "e2e", "agent_stub_advanced.mjs");

let PORT = 0;
let WS_URL = "";
let serverProcess: ReturnType<typeof Bun.spawn> | null = null;
let staticDir: string | null = null;
let testHome: string | null = null;

async function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createNetServer();
    srv.listen(0, "127.0.0.1", () => {
      const addr = srv.address();
      if (addr && typeof addr === "object") {
        srv.close(() => resolve(addr.port));
      } else {
        srv.close();
        reject(new Error("no port"));
      }
    });
    srv.on("error", reject);
  });
}

function waitForOpen(ws: WebSocket, ms = 5000): Promise<void> {
  return new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.OPEN) return resolve();
    const t = setTimeout(() => reject(new Error("ws open timeout")), ms);
    ws.once("open", () => {
      clearTimeout(t);
      resolve();
    });
    ws.once("error", (e) => {
      clearTimeout(t);
      reject(e);
    });
  });
}

function sendRequest(
  ws: WebSocket,
  method: string,
  params?: unknown,
  timeoutMs = 10000,
): Promise<{ id: number | string; result?: unknown; error?: unknown }> {
  return new Promise((resolve, reject) => {
    const id = Date.now() + Math.random();
    const t = setTimeout(() => {
      ws.off("message", handler);
      reject(new Error(`request timeout: ${method}`));
    }, timeoutMs);
    function handler(data: Buffer) {
      const msg = JSON.parse(data.toString());
      if (msg.id === id) {
        clearTimeout(t);
        ws.off("message", handler);
        resolve(msg);
      }
    }
    ws.on("message", handler);
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

function sendRequestWithId(
  ws: WebSocket,
  id: number,
  method: string,
  params?: unknown,
  timeoutMs = 15000,
): Promise<{ id: number | string; result?: unknown; error?: unknown }> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => {
      ws.off("message", handler);
      reject(new Error(`request timeout: ${method} id=${id}`));
    }, timeoutMs);
    function handler(data: Buffer) {
      const msg = JSON.parse(data.toString());
      if (msg.id === id) {
        clearTimeout(t);
        ws.off("message", handler);
        resolve(msg);
      }
    }
    ws.on("message", handler);
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

function collectMessages(ws: WebSocket, ms: number): Promise<unknown[]> {
  return new Promise((resolve) => {
    const msgs: unknown[] = [];
    const handler = (data: Buffer) => {
      msgs.push(JSON.parse(data.toString()));
    };
    ws.on("message", handler);
    setTimeout(() => {
      ws.off("message", handler);
      resolve(msgs);
    }, ms);
  });
}

async function createReadySession(ws: WebSocket): Promise<string> {
  const res = await sendRequest(ws, "session/new", { cwd: ROOT_CWD });
  const sessionId = (res.result as { sessionId: string }).sessionId;
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 250));
    const get = await sendRequest(ws, "session/get", { sessionId });
    const session = (get.result as { session: { status: string } }).session;
    if (session.status === "running") return sessionId;
    if (session.status === "error") throw new Error("session init failed");
  }
  throw new Error("session never became ready");
}

// ---------------------------------------------------------------------------
// suite
// ---------------------------------------------------------------------------

describe("Bug fixes", () => {
  beforeAll(async () => {
    PORT = await getFreePort();
    WS_URL = `ws://localhost:${PORT}/ws`;

    staticDir = mkdtempSync(join(tmpdir(), "acp-bugs-static-"));
    writeFileSync(join(staticDir, "index.html"), "<html></html>");

    testHome = mkdtempSync(join(tmpdir(), "acp-bugs-home-"));

    serverProcess = Bun.spawn(["bun", "run", "src/index.ts"], {
      cwd: SERVER_CWD,
      env: {
        ...process.env,
        PORT: String(PORT),
        STATIC_DIR: staticDir,
        HOME: testHome,
        AGENT_COMMAND: `node ${STUB}`,
      },
      stdout: "pipe",
      stderr: "pipe",
    });

    await new Promise((r) => setTimeout(r, 1500));
  });

  afterAll(() => {
    serverProcess?.kill();
    if (staticDir) rmSync(staticDir, { recursive: true, force: true });
    if (testHome) rmSync(testHome, { recursive: true, force: true });
  });

  // -------------------------------------------------------------------------
  // Bug 1: Request ID collision across clients
  // Two clients both send session/prompt with the SAME numeric id to
  // different sessions. Both should get their own response back.
  // -------------------------------------------------------------------------
  test("no request ID collision across two clients", async () => {
    const ws1 = new WebSocket(WS_URL);
    const ws2 = new WebSocket(WS_URL);
    await Promise.all([waitForOpen(ws1), waitForOpen(ws2)]);

    try {
      const sid1 = await createReadySession(ws1);
      const sid2 = await createReadySession(ws2);

      // Both use the same request id = 42
      const [r1, r2] = await Promise.all([
        sendRequestWithId(ws1, 42, "session/prompt", {
          sessionId: sid1,
          prompt: [{ type: "text", text: "echo hello-from-1" }],
        }),
        sendRequestWithId(ws2, 42, "session/prompt", {
          sessionId: sid2,
          prompt: [{ type: "text", text: "echo hello-from-2" }],
        }),
      ]);

      // Both should succeed -- neither should be lost
      expect(r1.result).toBeDefined();
      expect(r2.result).toBeDefined();
      expect((r1.result as { stopReason: string }).stopReason).toBe("end_turn");
      expect((r2.result as { stopReason: string }).stopReason).toBe("end_turn");
    } finally {
      ws1.close();
      ws2.close();
    }
  }, 30000);

  // -------------------------------------------------------------------------
  // Bug 2: pendingClientRequests not cleaned on agent death
  // Client sends a prompt, then the agent dies. The client should get an
  // error response, not hang forever.
  // -------------------------------------------------------------------------
  test("client gets error when agent dies during prompt", async () => {
    const ws = new WebSocket(WS_URL);
    await waitForOpen(ws);

    try {
      const sessionId = await createReadySession(ws);

      // Send "die" prompt -- agent will exit(1) without responding
      const response = await sendRequestWithId(ws, 99, "session/prompt", {
        sessionId,
        prompt: [{ type: "text", text: "die" }],
      });

      // Should get an error, not hang
      expect(response.error).toBeDefined();
    } finally {
      ws.close();
    }
  }, 30000);

  // -------------------------------------------------------------------------
  // Bug 3: cancel doesn't clean up pending prompt
  // Client sends a slow prompt, then cancels. The pending prompt should
  // receive an error/result, not hang.
  // -------------------------------------------------------------------------
  test("cancel cleans up pending prompt request", async () => {
    const ws = new WebSocket(WS_URL);
    await waitForOpen(ws);

    try {
      const sessionId = await createReadySession(ws);

      // Send slow prompt (agent won't respond)
      const promptPromise = sendRequestWithId(ws, 100, "session/prompt", {
        sessionId,
        prompt: [{ type: "text", text: "slow" }],
      });

      // Give the prompt a moment to reach the agent
      await new Promise((r) => setTimeout(r, 500));

      // Cancel the session
      await sendRequest(ws, "session/cancel", { sessionId });

      // The pending prompt should resolve (error or cancelled result)
      const result = await promptPromise;
      const gotResponse =
        result.error !== undefined || result.result !== undefined;
      expect(gotResponse).toBe(true);
    } finally {
      ws.close();
    }
  }, 30000);

  // -------------------------------------------------------------------------
  // Bug 4: sessionClients map leak -- after archive, pushes should stop
  // -------------------------------------------------------------------------
  test("archived session stops receiving pushes", async () => {
    const ws = new WebSocket(WS_URL);
    await waitForOpen(ws);

    try {
      const sessionId = await createReadySession(ws);

      // Archive the session
      await sendRequest(ws, "session/archive", { sessionId });

      // Collect messages for a short period
      const msgs = await collectMessages(ws, 1000);
      const pushesForSession = (
        msgs as Array<{ params?: { sessionId?: string } }>
      ).filter((m) => m.params?.sessionId === sessionId);

      expect(pushesForSession.length).toBe(0);
    } finally {
      ws.close();
    }
  }, 30000);
});
