import { useEffect, useRef, useCallback } from "react";
import { useAtom, useSetAtom } from "jotai";
import ReconnectingWebSocket from "reconnecting-websocket";
import {
  connectionStatusAtom,
  sessionsAtom,
  updateSessionAtom,
  addMessageAtom,
  appendToLastMessageAtom,
} from "../state/atoms";
import type { JsonRpcMessage, JsonRpcNotification, Session } from "../types/acp";

// Connect to same host, use wss if page is https
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
  const [sessions, setSessions] = useAtom(sessionsAtom);
  const updateSession = useSetAtom(updateSessionAtom);
  const addMessage = useSetAtom(addMessageAtom);
  const appendToLastMessage = useSetAtom(appendToLastMessageAtom);

  // Send a request and wait for response
  const sendRequest = useCallback(
    <T>(method: string, params?: unknown): Promise<T> => {
      return new Promise((resolve, reject) => {
        const id = nextId();
        const message = {
          jsonrpc: "2.0" as const,
          id,
          method,
          params,
        };

        pendingRequests.current.set(id, (result) => {
          resolve(result as T);
        });

        wsRef.current?.send(JSON.stringify(message));

        // Timeout after 30s
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

  // Handle incoming messages
  const handleMessage = useCallback(
    (data: string) => {
      try {
        const message = JSON.parse(data) as JsonRpcMessage & { _sessionId?: string };

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
          const handler = pendingRequests.current.get(message.id);
          if (handler) {
            pendingRequests.current.delete(message.id);
            console.error("RPC error:", message.error);
          }
          return;
        }

        // Notification from agent (via bridge)
        if ("method" in message) {
          handleNotification(message as JsonRpcNotification & { _sessionId?: string });
        }
      } catch (err) {
        console.error("Failed to parse message:", err);
      }
    },
    [updateSession, addMessage, appendToLastMessage]
  );

  const handleNotification = useCallback(
    (message: JsonRpcNotification & { _sessionId?: string }) => {
      const sessionId = message._sessionId || (message.params as { sessionId?: string })?.sessionId;

      switch (message.method) {
        case "session/update": {
          const params = message.params as { update: unknown };
          handleSessionUpdate(sessionId!, params.update);
          break;
        }
        case "session/ready": {
          if (sessionId) {
            updateSession({ id: sessionId, changes: { status: "running" } });
          }
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
          if (sessionId) {
            updateSession({ id: sessionId, changes: { status: "completed" } });
          }
          break;
        }
      }
    },
    [updateSession, addMessage, appendToLastMessage]
  );

  const handleSessionUpdate = useCallback(
    (sessionId: string, update: unknown) => {
      const u = update as { type: string; [key: string]: unknown };

      switch (u.type) {
        case "agent_message_chunk": {
          const content = u.content as string;
          // Check if we need to start a new message or append
          const session = sessions.get(sessionId);
          const lastMessage = session?.messages[session.messages.length - 1];

          if (lastMessage?.type === "agent") {
            appendToLastMessage({ sessionId, content });
          } else {
            addMessage({
              sessionId,
              message: {
                id: `msg_${Date.now()}`,
                type: "agent",
                content,
                timestamp: Date.now(),
              },
            });
          }
          break;
        }

        case "tool_call": {
          addMessage({
            sessionId,
            message: {
              id: u.id as string,
              type: "tool",
              content: `Using ${u.name}`,
              timestamp: Date.now(),
              toolCall: {
                id: u.id as string,
                name: u.name as string,
                status: u.status as "pending" | "running" | "completed" | "failed",
                fileLocations: u.fileLocations as { path: string; line?: number }[] | undefined,
              },
            },
          });
          break;
        }

        case "tool_call_update": {
          // Update existing tool call message
          const session = sessions.get(sessionId);
          if (session) {
            const messages = session.messages.map((m) => {
              if (m.id === u.id && m.toolCall) {
                return {
                  ...m,
                  toolCall: {
                    ...m.toolCall,
                    status: u.status as "pending" | "running" | "completed" | "failed",
                    fileLocations: (u.fileLocations as { path: string; line?: number }[]) || m.toolCall.fileLocations,
                  },
                };
              }
              return m;
            });
            updateSession({ id: sessionId, changes: { messages } });
          }
          break;
        }

        case "plan": {
          updateSession({
            id: sessionId,
            changes: { plan: u.entries as Session["plan"] },
          });
          break;
        }

        case "request_permission": {
          updateSession({
            id: sessionId,
            changes: {
              status: "waiting",
              pendingApproval: {
                id: u.id as string,
                toolName: u.toolName as string,
                input: u.input,
              },
            },
          });
          break;
        }
      }
    },
    [sessions, updateSession, addMessage, appendToLastMessage]
  );

  // Connect on mount
  useEffect(() => {
    setConnectionStatus("connecting");

    const ws = new ReconnectingWebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setConnectionStatus("connected");
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
  }, [handleMessage, setConnectionStatus]);

  // API methods
  const createSession = useCallback(
    async (title: string, cwd?: string) => {
      const result = await sendRequest<{ sessionId: string; status?: string }>("session/new", { cwd });

      const newSession: Session = {
        id: result.sessionId,
        status: result.status === "initializing" ? "waiting" : "running",
        title,
        messages: result.status === "initializing" ? [{
          id: `init_${Date.now()}`,
          type: "agent",
          content: "Initializing agent...",
          timestamp: Date.now(),
        }] : [],
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
      // Add user message to UI
      addMessage({
        sessionId,
        message: {
          id: `user_${Date.now()}`,
          type: "user",
          content: text,
          timestamp: Date.now(),
        },
      });

      updateSession({ id: sessionId, changes: { status: "running" } });

      await sendRequest("session/prompt", {
        sessionId,
        prompt: [{ type: "text", text }],
      });
    },
    [sendRequest, addMessage, updateSession]
  );

  const respondToPermission = useCallback(
    async (sessionId: string, permissionId: string, allow: boolean) => {
      updateSession({
        id: sessionId,
        changes: { pendingApproval: undefined, status: "running" },
      });

      await sendRequest("session/respond_permission", {
        sessionId,
        permissionId,
        response: allow ? "allow_once" : "reject_once",
      });
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

  return {
    connectionStatus,
    createSession,
    sendPrompt,
    respondToPermission,
    cancelSession,
  };
}
