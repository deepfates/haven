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
} from "../state/atoms";
import type { JsonRpcMessage, JsonRpcNotification, Session } from "../types/acp";

const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
const WS_URL = import.meta.env.VITE_WS_URL || `${protocol}//${window.location.host}/ws`;

let requestId = 0;
function nextId() {
  return ++requestId;
}

// Types for service API responses
interface ServiceSession {
  id: string;
  agentType: string;
  cwd: string;
  title: string | null;
  status: string;
  exitReason: string | null;
  createdAt: string;
  updatedAt: string;
}

interface ServiceUpdate {
  seq: number;
  updateType: string;
  payload: {
    sessionUpdate: string;
    content?: { type: string; text?: string };
    toolCallId?: string;
    title?: string;
    status?: string;
    locations?: { path: string; line?: number }[];
    rawOutput?: unknown;
    entries?: Session["plan"];
    [key: string]: unknown;
  };
  createdAt: string;
}

interface PendingRequest {
  requestId: string;
  requestType: string;
  payload: {
    toolCall?: { id: string; name: string; rawInput?: unknown };
    options?: { optionId: string; name: string; kind: string }[];
  };
}

export function useAcpConnection() {
  const wsRef = useRef<ReconnectingWebSocket | null>(null);
  const pendingRequests = useRef<Map<number | string, (result: unknown) => void>>(new Map());
  const pendingRejects = useRef<Map<number | string, (error: Error) => void>>(new Map());

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
        pendingRejects.current.set(id, reject);
        wsRef.current?.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
        setTimeout(() => {
          if (pendingRequests.current.has(id)) {
            pendingRequests.current.delete(id);
            pendingRejects.current.delete(id);
            reject(new Error("Request timeout"));
          }
        }, 30000);
      });
    },
    []
  );

  // Process a session update from the service
  const processUpdate = useCallback(
    (sessionId: string, update: ServiceUpdate) => {
      const payload = update.payload;

      switch (payload.sessionUpdate) {
        case "user_message_chunk":
        case "user_message": {
          // User messages are already added optimistically, skip duplicates
          break;
        }

        case "agent_message_chunk": {
          const text = payload.content?.text || "";
          appendToLastMessage({ sessionId, content: text });
          break;
        }

        case "tool_call": {
          const toolCallId = payload.toolCallId as string;
          const title = payload.title as string;
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
                status: (payload.status || "pending") as "pending" | "running" | "completed" | "failed",
                fileLocations: payload.locations,
                rawOutput: payload.rawOutput,
              },
            },
          });
          break;
        }

        case "tool_call_update": {
          updateToolCall({
            sessionId,
            toolCallId: payload.toolCallId as string,
            status: payload.status as string,
            locations: payload.locations,
            rawOutput: payload.rawOutput,
          });
          break;
        }

        case "plan": {
          updateSession({
            id: sessionId,
            changes: { plan: payload.entries },
          });
          break;
        }
      }
    },
    [addMessage, appendToLastMessage, updateToolCall, updateSession]
  );

  // Handle notifications from service
  const handleNotification = useCallback(
    (message: JsonRpcNotification) => {
      const params = message.params as { sessionId?: string; [key: string]: unknown };
      const sessionId = params?.sessionId;

      switch (message.method) {
        case "session/updated": {
          // New updates for a session
          const updates = params.updates as ServiceUpdate[];
          if (sessionId && updates) {
            for (const update of updates) {
              processUpdate(sessionId, update);
            }
          }
          break;
        }

        case "session/status_changed": {
          // Session status changed
          if (sessionId) {
            const status = params.status as string;
            const exitReason = params.exitReason as string | undefined;

            const statusMap: Record<string, Session["status"]> = {
              initializing: "waiting",
              running: "running",
              waiting: "waiting",
              completed: "completed",
              error: "error",
              exited: "completed",
            };

            updateSession({
              id: sessionId,
              changes: {
                status: statusMap[status] || "running",
              },
            });

            if (status === "exited" || status === "error") {
              addMessage({
                sessionId,
                message: {
                  id: `status_${Date.now()}`,
                  type: "agent",
                  content: exitReason ? `Session ended: ${exitReason}` : "Session ended",
                  timestamp: Date.now(),
                },
              });
            }
          }
          break;
        }

        case "session/request": {
          // Agent is requesting something (permission)
          if (sessionId) {
            const requestId = params.requestId as string | number;
            const request = params.request as PendingRequest["payload"];

            if (request?.toolCall && request?.options) {
              updateSession({
                id: sessionId,
                changes: {
                  status: "waiting",
                  pendingApproval: {
                    requestId,
                    id: request.toolCall.id,
                    toolName: request.toolCall.name,
                    input: request.toolCall.rawInput,
                    options: request.options as Session["pendingApproval"] extends { options: infer O } ? O : never,
                  },
                },
              });
            }
          }
          break;
        }
      }
    },
    [processUpdate, updateSession, addMessage]
  );

  // Handle incoming WebSocket messages
  const handleMessage = useCallback(
    (data: string) => {
      try {
        const message = JSON.parse(data) as JsonRpcMessage;

        // Response to our request
        if ("id" in message && "result" in message) {
          const handler = pendingRequests.current.get(message.id);
          if (handler) {
            pendingRequests.current.delete(message.id);
            pendingRejects.current.delete(message.id);
            handler(message.result);
          }
          return;
        }

        // Error response
        if ("id" in message && "error" in message) {
          const rejecter = pendingRejects.current.get(message.id);
          if (rejecter) {
            pendingRequests.current.delete(message.id);
            pendingRejects.current.delete(message.id);
            const err = message.error as { message?: string };
            rejecter(new Error(err?.message || "Unknown error"));
          } else {
            console.error("RPC error:", message.error);
          }
          return;
        }

        // Notification from service
        if ("method" in message && !("id" in message)) {
          handleNotification(message as JsonRpcNotification);
        }
      } catch (err) {
        console.error("Failed to parse message:", err);
      }
    },
    [handleNotification]
  );

  // Convert service session to client session
  const serviceToClientSession = (s: ServiceSession, messages: Session["messages"] = []): Session => ({
    id: s.id,
    title: s.title || "Session",
    status: (s.status === "exited" ? "completed" : s.status) as Session["status"],
    messages,
  });

  // Load a session's full data
  const loadSession = useCallback(
    async (sessionId: string) => {
      try {
        const result = await sendRequest<{
          session: ServiceSession;
          updates: ServiceUpdate[];
          pendingRequests: PendingRequest[];
        }>("session/get", { sessionId });

        // Build messages from updates
        const messages: Session["messages"] = [];
        let lastAgentMessage: Session["messages"][0] | null = null;

        for (const update of result.updates) {
          const payload = update.payload;

          switch (payload.sessionUpdate) {
            case "user_message":
            case "user_message_chunk": {
              let text = payload.content?.text || "";
              // Handle legacy format where text was JSON.stringify'd prompt array
              if (text.startsWith("[{") && text.includes('"type":"text"')) {
                try {
                  const parsed = JSON.parse(text) as Array<{ type: string; text?: string }>;
                  text = parsed[0]?.text || text;
                } catch {
                  // Keep original if parse fails
                }
              }
              if (text) {
                messages.push({
                  id: `user_${update.seq}`,
                  type: "user",
                  content: text,
                  timestamp: new Date(update.createdAt).getTime(),
                });
              }
              lastAgentMessage = null;
              break;
            }

            case "agent_message_chunk": {
              const text = payload.content?.text || "";
              if (lastAgentMessage && lastAgentMessage.type === "agent") {
                lastAgentMessage.content += text;
              } else {
                lastAgentMessage = {
                  id: `agent_${update.seq}`,
                  type: "agent",
                  content: text,
                  timestamp: new Date(update.createdAt).getTime(),
                };
                messages.push(lastAgentMessage);
              }
              break;
            }

            case "tool_call": {
              messages.push({
                id: payload.toolCallId || `tool_${update.seq}`,
                type: "tool",
                content: payload.title || "Tool call",
                timestamp: new Date(update.createdAt).getTime(),
                toolCall: {
                  id: payload.toolCallId || `tool_${update.seq}`,
                  name: payload.title || "",
                  status: (payload.status || "pending") as "pending" | "running" | "completed" | "failed",
                  fileLocations: payload.locations,
                  rawOutput: payload.rawOutput,
                },
              });
              lastAgentMessage = null;
              break;
            }
          }
        }

        // Build session
        const session = serviceToClientSession(result.session, messages);

        // Add pending approval if any
        if (result.pendingRequests.length > 0) {
          const pending = result.pendingRequests[0];
          if (pending.payload.toolCall && pending.payload.options) {
            session.pendingApproval = {
              requestId: pending.requestId,
              id: pending.payload.toolCall.id,
              toolName: pending.payload.toolCall.name,
              input: pending.payload.toolCall.rawInput,
              options: pending.payload.options as Session["pendingApproval"] extends { options: infer O } ? O : never,
            };
            session.status = "waiting";
          }
        }

        setSessions((prev) => {
          const next = new Map(prev);
          next.set(sessionId, session);
          return next;
        });

        return session;
      } catch (err) {
        console.error(`[loadSession] Failed:`, err);
        throw err;
      }
    },
    [sendRequest, setSessions]
  );

  // Fetch all sessions on connect
  const fetchSessions = useCallback(async () => {
    try {
      const result = await sendRequest<{ sessions: ServiceSession[] }>("session/list");

      console.log("[ACP] Sessions:", result.sessions);

      // Update sessions map
      setSessions((prev) => {
        const next = new Map(prev);
        const serverIds = new Set(result.sessions.map((s) => s.id));

        // Mark sessions not on server as completed
        for (const [id, session] of next) {
          if (!serverIds.has(id) && session.status !== "completed" && session.status !== "error") {
            next.set(id, { ...session, status: "completed" });
          }
        }

        // Add/update sessions from server
        for (const s of result.sessions) {
          const existing = next.get(s.id);
          if (existing) {
            // Update status but keep messages
            next.set(s.id, {
              ...existing,
              title: s.title || existing.title,
              status: (s.status === "exited" ? "completed" : s.status) as Session["status"],
            });
          } else {
            // New session, will load details when opened
            next.set(s.id, serviceToClientSession(s));
          }
        }

        return next;
      });
    } catch (err) {
      console.error("[ACP] Fetch sessions failed:", err);
    }
  }, [sendRequest, setSessions]);

  // Connect on mount
  useEffect(() => {
    setConnectionStatus("connecting");

    const ws = new ReconnectingWebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setConnectionStatus("connected");
      fetchSessions();
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
  }, [handleMessage, setConnectionStatus, fetchSessions]);

  // API
  const createSession = useCallback(
    async (title: string, cwd?: string) => {
      const result = await sendRequest<{ sessionId: string }>("session/new", { title, cwd });

      const newSession: Session = {
        id: result.sessionId,
        status: "waiting",
        title,
        messages: [{ id: `init_${Date.now()}`, type: "agent", content: "Initializing...", timestamp: Date.now() }],
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
    async (sessionId: string, requestId: string | number, optionId: string) => {
      updateSession({ id: sessionId, changes: { pendingApproval: undefined, status: "running" } });

      try {
        await sendRequest("session/respond", {
          sessionId,
          requestId: String(requestId),
          response: { outcome: { outcome: "selected", optionId } },
        });
      } catch (err) {
        console.error("[respondToPermission] Failed:", err);
      }
    },
    [sendRequest, updateSession]
  );

  const cancelSession = useCallback(
    async (sessionId: string) => {
      await sendRequest("session/cancel", { sessionId });
      updateSession({ id: sessionId, changes: { status: "completed" } });
    },
    [sendRequest, updateSession]
  );

  const archiveSession = useCallback(
    async (sessionId: string) => {
      await sendRequest("session/archive", { sessionId });
      setSessions((prev) => {
        const next = new Map(prev);
        next.delete(sessionId);
        return next;
      });
    },
    [sendRequest, setSessions]
  );

  return {
    connectionStatus,
    createSession,
    sendPrompt,
    respondToPermission,
    cancelSession,
    archiveSession,
    loadSession,
  };
}
