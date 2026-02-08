#!/usr/bin/env node
/**
 * Advanced agent stub for integration testing.
 *
 * Behaviour is controlled by the prompt text:
 *   "echo <text>"          → replies with agent_message_chunk containing <text>
 *   "permission"            → sends a session/request_permission before replying
 *   "slow"                  → waits 60 s before replying (to test cancel / death)
 *   "die"                   → exits immediately without responding (simulates crash)
 *   anything else           → default echo
 */
import { createInterface } from "node:readline";

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

let nextPermId = 1;

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }

  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { capabilities: {} } });
    return;
  }

  if (msg.method === "session/new") {
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: "agent_session_1" } });
    return;
  }

  if (msg.method === "session/prompt") {
    const promptBlocks = msg.params?.prompt || [];
    const text = promptBlocks[0]?.text || "";

    if (text.startsWith("echo ")) {
      const reply = text.slice(5);
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } },
        },
      });
      send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
      return;
    }

    if (text === "permission") {
      const permId = nextPermId++;
      send({
        jsonrpc: "2.0",
        id: permId,
        method: "session/request_permission",
        params: {
          sessionId: msg.params?.sessionId,
          toolCall: { toolCallId: `tool_${permId}`, title: "Test tool", status: "pending" },
          options: [
            { optionId: "allow", name: "Allow", kind: "allow_once" },
            { optionId: "deny", name: "Deny", kind: "reject_once" },
          ],
        },
      });
      // Will wait for permission response, then reply
      // Store msg.id so we can respond after permission
      const promptId = msg.id;
      const handler = (permLine) => {
        if (!permLine.trim()) return;
        let permMsg;
        try { permMsg = JSON.parse(permLine); } catch { return; }
        if (permMsg.id === permId && "result" in permMsg) {
          rl.removeListener("line", handler);
          send({
            jsonrpc: "2.0",
            method: "session/update",
            params: {
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "permission granted" } },
            },
          });
          send({ jsonrpc: "2.0", id: promptId, result: { stopReason: "end_turn" } });
        }
      };
      rl.on("line", handler);
      return;
    }

    if (text === "slow") {
      // Don't respond -- simulates a long-running prompt
      // The test should cancel or kill us
      return;
    }

    if (text === "die") {
      // Exit without responding to simulate a crash
      process.exit(1);
    }

    // Default: echo
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
      },
    });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
    return;
  }

  if (msg.method === "session/cancel") {
    return;
  }
});
