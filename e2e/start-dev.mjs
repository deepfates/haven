import { spawn } from "node:child_process";
import { join } from "node:path";

const ROOT = process.cwd();
const PORT = Number(process.env.ACP_E2E_SERVER_PORT || 8090);
const VITE_PORT = Number(process.env.ACP_E2E_VITE_PORT || 5173);
const HOME_DIR = join(ROOT, ".tmp", "acp-client-home");
const AGENT = join(ROOT, "e2e", "agent_stub.mjs");

const server = spawn("bun", ["run", "dev"], {
  cwd: join(ROOT, "server"),
  env: {
    ...process.env,
    HOME: HOME_DIR,
    PORT: String(PORT),
    DEFAULT_CWD: ROOT,
    AGENT_COMMAND: AGENT,
  },
  stdio: "inherit",
});

const client = spawn("bun", ["run", "dev", "--", "--host", "127.0.0.1", "--port", String(VITE_PORT), "--strictPort"], {
  cwd: join(ROOT, "client"),
  env: {
    ...process.env,
    VITE_WS_URL: `ws://localhost:${PORT}/ws`,
  },
  stdio: "inherit",
});

function shutdown(code = 0) {
  server.kill();
  client.kill();
  process.exit(code);
}

server.on("exit", (code) => {
  if (code && code !== 0) shutdown(code);
});

client.on("exit", (code) => {
  if (code && code !== 0) shutdown(code);
});

process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));
