import type { JsonRpcMessage } from "./types.js";
import type { Subprocess, FileSink } from "bun";

type MessageHandler = (message: JsonRpcMessage) => void;

export class AgentConnection {
  private process: Subprocess<"pipe", "pipe", "pipe"> | null = null;
  private buffer = "";
  private onMessage: MessageHandler;
  private onClose: () => void;

  constructor(
    private sessionId: string,
    private cwd: string,
    private agentCommand: string,
    handlers: { onMessage: MessageHandler; onClose: () => void },
  ) {
    this.onMessage = handlers.onMessage;
    this.onClose = handlers.onClose;
  }

  async start(): Promise<void> {
    // Use shell to properly handle PATH, shebang scripts, and version managers like nvm
    this.process = Bun.spawn(["sh", "-c", this.agentCommand], {
      cwd: this.cwd,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      env: process.env,
    });

    this.readStdout();
    this.readStderr();

    this.process.exited.then(() => {
      this.onClose();
    });
  }

  private async readStdout() {
    const stdout = this.process?.stdout;
    if (!stdout || typeof stdout === "number") return;

    const reader = stdout.getReader();
    const decoder = new TextDecoder();

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        this.buffer += decoder.decode(value, { stream: true });
        this.processBuffer();
      }
    } catch (err) {
      console.error(`[${this.sessionId}] stdout read error:`, err);
    }
  }

  private async readStderr() {
    const stderr = this.process?.stderr;
    if (!stderr || typeof stderr === "number") return;

    const reader = stderr.getReader();
    const decoder = new TextDecoder();

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const text = decoder.decode(value, { stream: true });
        console.error(`[${this.sessionId}] stderr:`, text);
      }
    } catch (err) {
      console.error(`[${this.sessionId}] stderr read error:`, err);
    }
  }

  private processBuffer() {
    // ACP uses newline-delimited JSON
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop() || "";

    for (const line of lines) {
      if (!line.trim()) continue;

      try {
        const message = JSON.parse(line) as JsonRpcMessage;
        this.onMessage(message);
      } catch (err) {
        console.error(`[${this.sessionId}] parse error:`, err, "line:", line);
      }
    }
  }

  send(message: JsonRpcMessage): void {
    const stdin = this.process?.stdin;
    if (!stdin || typeof stdin === "number") {
      console.error(`[${this.sessionId}] cannot send: stdin not available`);
      return;
    }

    const line = JSON.stringify(message) + "\n";
    (stdin as FileSink).write(line);
    (stdin as FileSink).flush();
  }

  kill(): void {
    this.process?.kill();
    this.process = null;
  }

  get isRunning(): boolean {
    return this.process !== null;
  }
}
