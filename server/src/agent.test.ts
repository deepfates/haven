import { describe, test, expect, mock } from "bun:test";

// Test the buffer processing logic in isolation
describe("Agent Message Buffer", () => {
  // Simulating the buffer processing from AgentConnection
  function processBuffer(buffer: string): { messages: unknown[]; remainder: string } {
    const lines = buffer.split("\n");
    const remainder = lines.pop() || "";
    const messages: unknown[] = [];

    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        messages.push(JSON.parse(line));
      } catch {
        // Skip invalid JSON
      }
    }

    return { messages, remainder };
  }

  test("parses single complete message", () => {
    const buffer = '{"jsonrpc":"2.0","method":"test"}\n';
    const { messages, remainder } = processBuffer(buffer);

    expect(messages).toHaveLength(1);
    expect(messages[0]).toEqual({ jsonrpc: "2.0", method: "test" });
    expect(remainder).toBe("");
  });

  test("handles multiple messages", () => {
    const buffer = '{"jsonrpc":"2.0","id":1}\n{"jsonrpc":"2.0","id":2}\n';
    const { messages, remainder } = processBuffer(buffer);

    expect(messages).toHaveLength(2);
    expect(remainder).toBe("");
  });

  test("preserves incomplete message in remainder", () => {
    const buffer = '{"jsonrpc":"2.0","id":1}\n{"incomplete';
    const { messages, remainder } = processBuffer(buffer);

    expect(messages).toHaveLength(1);
    expect(remainder).toBe('{"incomplete');
  });

  test("handles empty lines", () => {
    const buffer = '{"id":1}\n\n{"id":2}\n';
    const { messages } = processBuffer(buffer);

    expect(messages).toHaveLength(2);
  });

  test("skips invalid JSON", () => {
    const buffer = 'not json\n{"valid":true}\n';
    const { messages } = processBuffer(buffer);

    expect(messages).toHaveLength(1);
    expect(messages[0]).toEqual({ valid: true });
  });
});

describe("Session Update Types", () => {
  test("agent_message_chunk structure", () => {
    const update = {
      type: "agent_message_chunk",
      content: "Hello, I'm working on that now.",
    };

    expect(update.type).toBe("agent_message_chunk");
    expect(typeof update.content).toBe("string");
  });

  test("tool_call structure", () => {
    const update = {
      type: "tool_call",
      id: "tool_123",
      name: "Read",
      status: "running" as const,
      fileLocations: [{ path: "/home/sprite/test.ts", line: 42 }],
    };

    expect(update.type).toBe("tool_call");
    expect(update.name).toBe("Read");
    expect(update.fileLocations).toHaveLength(1);
  });

  test("request_permission structure", () => {
    const update = {
      type: "request_permission",
      id: "perm_456",
      toolName: "Bash",
      input: { command: "npm install" },
    };

    expect(update.type).toBe("request_permission");
    expect(update.toolName).toBe("Bash");
  });
});

describe("JSON-RPC Protocol", () => {
  test("request has id", () => {
    const request = {
      jsonrpc: "2.0" as const,
      id: 1,
      method: "session/prompt",
      params: { sessionId: "test", content: [] },
    };

    expect("id" in request).toBe(true);
  });

  test("notification has no id", () => {
    const notification = {
      jsonrpc: "2.0" as const,
      method: "session/update",
      params: { update: { type: "agent_message_chunk", content: "test" } },
    };

    expect("id" in notification).toBe(false);
  });

  test("response matches request id", () => {
    const request = { jsonrpc: "2.0" as const, id: 42, method: "test" };
    const response = { jsonrpc: "2.0" as const, id: 42, result: { success: true } };

    expect(response.id).toBe(request.id);
  });

  test("error response structure", () => {
    const errorResponse = {
      jsonrpc: "2.0" as const,
      id: 1,
      error: {
        code: -32602,
        message: "Invalid params",
      },
    };

    expect(errorResponse.error.code).toBe(-32602);
    expect(typeof errorResponse.error.message).toBe("string");
  });
});
