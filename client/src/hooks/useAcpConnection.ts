import { useEffect, useRef, useCallback } from "react";
import { useAtom, useSetAtom } from "jotai";
import ReconnectingWebSocket from "reconnecting-websocket";
import {
  connectionStatusAtom,
  sessionsAtom,
  updateSessionAtom,
  addMessageAtom,
  appendToLastMessageAtom,
  updateToolCallAtom,
  getLastSeq,
  updateLastSeq,
} from "../state/atoms";
import type { JsonRpcMessage, JsonRpcNotification, JsonRpcRequest, Session } from "../types/acp";

const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
const WS_URL = import.meta.env.VITE_WS_URL || `${protocol}//${window.location.host}`;

let requestId = 0;
function nextId() {
  return ++requestId;
}

export function useAcpConnection() {
  const wsRef = useRef<ReconnectingWebSocket | null>(null);
  const pendingRequests = useRef<Map<number | string, (result: unknown) => void>>(new Map());

  const [connectionStatus, setConnectionStatus] = useAtom(connectionStatusAtom);
  const [, setSessions] = useAtom(sessionsAtom);
  const updateSession = useSetAtom(updateSessionAtom);
  const addMessage = useSetAtom(addMessageAtom);
  const appendToLastMessage = useSetAtom(appendToLastMessageAtom);
  const updateToolCall = useSetAtom(updateToolCallAtom);

  // Send a request and wait for response
  const sendRequest = useCallback(
    <T>(method: string, params?: unknown): Promise<T> => {
      return new Promise((resolve, reject) => {
        const id = nextId();
        pendingRequests.current.set(id, (result) => resolve(result as T));
        wsRef.current?.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
        setTimeout(() => {
          if (pendingRequests.current.has(id)) {
            pendingRequests.current.delete(id);
            reject(new Error("Request timeout"));
          }
        }, 30000);
      });
    },
    []
  );

  // Handle session update notifications (tool calls, message chunks, etc.)
  const handleSessionUpdate = useCallback(
    (sessionId: string, update: unknown) => {
      const u = update as { sessionUpdate: string; [key: string]: unknown };

      switch (u.sessionUpdate) {
        case "agent_message_chunk": {
          const contentBlock = u.content as { type: string; text?: string };
          const text = contentBlock?.text || "";
          appendToLastMessage({ sessionId, content: text });
          break;
        }

        case "tool_call": {
          const toolCallId = u.toolCallId as string;
          const title = u.title as string;
          addMessage({
            sessionId,
            message: {
              id: toolCallId,
              type: "tool",
              content: title || "Tool call",
              timestamp: Date.now(),
              toolCall: {
                id: toolCallId,
                name: title,
                status: ((u.status as string) || "pending") as "pending" | "running" | "completed" | "failed",
                fileLocations: u.locations as { path: string; line?: number }[] | undefined,
                rawOutput: u.rawOutput,
              },
            },
          });
          break;
        }

        case "tool_call_update": {
          updateToolCall({
            sessionId,
            toolCallId: u.toolCallId as string,
            status: u.status as string,
            locations: u.locations as { path: string; line?: number }[],
            rawOutput: u.rawOutput,
          });
          break;
        }

        case "plan": {
          updateSession({
            id: sessionId,
            changes: { plan: u.entries as Session["plan"] },
          });
          break;
        }
      }
    },
    [updateSession, addMessage, appendToLastMessage, updateToolCall]
  );

  // Handle notifications from agent
  const handleNotification = useCallback(
    (message: JsonRpcNotification & { _sessionId?: string }) => {
      const sessionId = message._sessionId || (message.params as { sessionId?: string })?.sessionId;

      switch (message.method) {
        case "session/update": {
          const params = message.params as { update: unknown };
          if (sessionId) handleSessionUpdate(sessionId, params.update);
          break;
        }
        case "session/ready": {
          if (sessionId) updateSession({ id: sessionId, changes: { status: "running" } });
          break;
        }
        case "session/error": {
          if (sessionId) {
            const params = message.params as { error?: string };
            updateSession({ id: sessionId, changes: { status: "error" } });
            addMessage({
              sessionId,
              message: {
                id: `error_${Date.now()}`,
                type: "agent",
                content: `Error: ${params.error || "Unknown error"}`,
                timestamp: Date.now(),
              },
            });
          }
          break;
        }
        case "session/closed": {
          if (sessionId) updateSession({ id: sessionId, changes: { status: "completed" } });
          break;
        }
      }
    },
    [updateSession, addMessage, handleSessionUpdate]
  );

  // Handle requests from agent (like permission requests)
  const handleAgentRequest = useCallback(
    (message: JsonRpcRequest & { _sessionId?: string }) => {
      const sessionId = message._sessionId || (message.params as { sessionId?: string })?.sessionId;

      if (message.method === "session/request_permission" && sessionId) {
        const params = message.params as {
          toolCall: { id: string; name: string; rawInput?: unknown };
          options: { optionId: string; name: string; kind: "allow_once" | "allow_always" | "reject_once" | "reject_always" }[];
        };

        updateSession({
          id: sessionId,
          changes: {
            status: "waiting",
            pendingApproval: {
              requestId: message.id,
              id: params.toolCall.id,
              toolName: params.toolCall.name,
              input: params.toolCall.rawInput,
              options: params.options,
            },
          },
        });
      }
    },
    [updateSession]
  );

  // Process a message (notification or request from agent)
  const processMessage = useCallback(
    (message: JsonRpcMessage & { _sessionId?: string; _seq?: number }) => {
      // Track sequence number
      if (message._sessionId && typeof message._seq === "number") {
        updateLastSeq(message._sessionId, message._seq);
      }

      if ("method" in message && !("id" in message)) {
        handleNotification(message as JsonRpcNotification & { _sessionId?: string });
      } else if ("method" in message && "id" in message) {
        handleAgentRequest(message as JsonRpcRequest & { _sessionId?: string });
      }
    },
    [handleNotification, handleAgentRequest]
  );

  // Handle incoming WebSocket messages
  const handleMessage = useCallback(
    (data: string) => {
      try {
        const message = JSON.parse(data) as JsonRpcMessage & { _sessionId?: string; _seq?: number };

        // Response to our request
        if ("id" in message && "result" in message) {
          const handler = pendingRequests.current.get(message.id);
          if (handler) {
            pendingRequests.current.delete(message.id);
            handler(message.result);
          }
          return;
        }

        // Error response
        if ("id" in message && "error" in message) {
          pendingRequests.current.delete(message.id);
          console.error("RPC error:", message.error);
          return;
        }

        // Process agent message
        processMessage(message);
      } catch (err) {
        console.error("Failed to parse message:", err);
      }
    },
    [processMessage]
  );

  // Sync a session - replay missed messages
  const syncSession = useCallback(
    async (sessionId: string) => {
      const lastSeq = getLastSeq(sessionId);
      console.log(`[sync] Session ${sessionId} from seq ${lastSeq}`);

      try {
        const result = await sendRequest<{
          sessionId: string;
          status: string;
          messages: Array<JsonRpcMessage & { _sessionId: string; _seq: number }>;
          currentSeq: number;
        }>("session/sync", { sessionId, lastSeq });

        console.log(`[sync] Replaying ${result.messages.length} messages`);

        for (const msg of result.messages) {
          processMessage(msg);
        }

        const statusMap: Record<string, Session["status"]> = {
          ready: "running",
          initializing: "waiting",
          error: "error",
          closed: "completed",
        };

        updateSession({
          id: sessionId,
          changes: { status: statusMap[result.status] || "running" },
        });
      } catch (err) {
        console.error(`[sync] Failed:`, err);
      }
    },
    [sendRequest, processMessage, updateSession]
  );

  // Restore sessions on reconnect
  const restoreSessions = useCallback(async () => {
    try {
      const result = await sendRequest<{
        sessions: Array<{ id: string; status: string; lastSeq: number }>;
      }>("session/list");

      console.log("[ACP] Sessions:", result.sessions);

      const serverIds = new Set(result.sessions.map((s) => s.id));

      // Mark dead sessions
      setSessions((prev) => {
        const next = new Map(prev);
        for (const [id, session] of next) {
          if (!serverIds.has(id) && session.status !== "completed" && session.status !== "error") {
            next.set(id, { ...session, status: "completed", pendingApproval: undefined });
          }
        }
        return next;
      });

      // Sync each server session
      for (const s of result.sessions) {
        setSessions((prev) => {
          if (!prev.has(s.id)) {
            const next = new Map(prev);
            next.set(s.id, { id: s.id, status: "running", title: "Session", messages: [] });
            return next;
          }
          return prev;
        });

        await syncSession(s.id);
      }
    } catch (err) {
      console.error("[ACP] Restore failed:", err);
    }
  }, [sendRequest, setSessions, syncSession]);

  // Connect on mount
  useEffect(() => {
    setConnectionStatus("connecting");

    const ws = new ReconnectingWebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setConnectionStatus("connected");
      restoreSessions();
    };

    ws.onclose = () => {
      setConnectionStatus("disconnected");
    };

    ws.onmessage = (event) => {
      handleMessage(event.data);
    };

    ws.onerror = (err) => {
      console.error("WebSocket error:", err);
    };

    return () => {
      ws.close();
    };
  }, [handleMessage, setConnectionStatus, restoreSessions]);

  // API
  const createSession = useCallback(
    async (title: string, cwd?: string) => {
      const result = await sendRequest<{ sessionId: string; status?: string }>("session/new", { cwd });

      const newSession: Session = {
        id: result.sessionId,
        status: result.status === "initializing" ? "waiting" : "running",
        title,
        messages:
          result.status === "initializing"
            ? [{ id: `init_${Date.now()}`, type: "agent", content: "Initializing...", timestamp: Date.now() }]
            : [],
      };

      setSessions((prev) => {
        const next = new Map(prev);
        next.set(result.sessionId, newSession);
        return next;
      });

      return result.sessionId;
    },
    [sendRequest, setSessions]
  );

  const sendPrompt = useCallback(
    async (sessionId: string, text: string) => {
      addMessage({
        sessionId,
        message: { id: `user_${Date.now()}`, type: "user", content: text, timestamp: Date.now() },
      });

      updateSession({ id: sessionId, changes: { status: "running" } });

      try {
        await sendRequest("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
      } catch (err) {
        console.error("[sendPrompt] Failed:", err);
        addMessage({
          sessionId,
          message: {
            id: `error_${Date.now()}`,
            type: "agent",
            content: `Failed to send message: ${err instanceof Error ? err.message : "Unknown error"}`,
            timestamp: Date.now(),
          },
        });
        updateSession({ id: sessionId, changes: { status: "error" } });
      }
    },
    [sendRequest, addMessage, updateSession]
  );

  const respondToPermission = useCallback(
    (sessionId: string, requestId: string | number, optionId: string) => {
      updateSession({ id: sessionId, changes: { pendingApproval: undefined, status: "running" } });
      wsRef.current?.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id: requestId,
          result: { outcome: { outcome: "selected", optionId } },
        })
      );
    },
    [updateSession]
  );

  const cancelSession = useCallback(
    async (sessionId: string) => {
      await sendRequest("session/cancel", { sessionId });
      updateSession({ id: sessionId, changes: { status: "completed" } });
    },
    [sendRequest, updateSession]
  );

  return { connectionStatus, createSession, sendPrompt, respondToPermission, cancelSession };
}
