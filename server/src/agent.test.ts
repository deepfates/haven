import { describe, test, expect, mock } from "bun:test";

// Test the buffer processing logic in isolation
describe("Agent Message Buffer", () => {
  // Simulating the buffer processing from AgentConnection
  function processBuffer(buffer: string): {
    messages: unknown[];
    remainder: string;
  } {
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

describe("Session Update Types (ACP spec)", () => {
  test("agent_message_chunk structure", () => {
    const update = {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "Hello, I'm working on that now." },
    };

    expect(update.sessionUpdate).toBe("agent_message_chunk");
    expect(update.content.type).toBe("text");
    expect(typeof update.content.text).toBe("string");
  });

  test("tool_call structure", () => {
    const update = {
      sessionUpdate: "tool_call",
      toolCallId: "tool_123",
      title: "Read",
      status: "in_progress" as const,
      locations: [{ path: "/home/user/test.ts", line: 42 }],
    };

    expect(update.sessionUpdate).toBe("tool_call");
    expect(update.title).toBe("Read");
    expect(update.toolCallId).toBe("tool_123");
    expect(update.locations).toHaveLength(1);
  });

  test("request_permission is a JSON-RPC request, not an update", () => {
    // Per ACP spec, permissions are sent as JSON-RPC requests from agent to
    // client, not as session/update notifications.
    const permRequest = {
      jsonrpc: "2.0" as const,
      id: 1,
      method: "session/request_permission",
      params: {
        sessionId: "sess_1",
        toolCall: { toolCallId: "tool_1", title: "Bash", status: "pending" },
        options: [
          { optionId: "allow", name: "Allow", kind: "allow_once" },
          { optionId: "deny", name: "Deny", kind: "reject_once" },
        ],
      },
    };

    expect(permRequest.method).toBe("session/request_permission");
    expect(permRequest.params.options).toHaveLength(2);
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
    const response = {
      jsonrpc: "2.0" as const,
      id: 42,
      result: { success: true },
    };

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
