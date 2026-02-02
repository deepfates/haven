import { defineConfig } from "playwright/test";

const VITE_PORT = 5173;

export default defineConfig({
  testDir: "e2e",
  testMatch: "**/*.e2e.ts",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  retries: 0,
  use: {
    baseURL: `http://localhost:${VITE_PORT}`,
    trace: "retain-on-failure",
  },
  webServer: {
    command: "node e2e/start-dev.mjs",
    url: `http://localhost:${VITE_PORT}`,
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
