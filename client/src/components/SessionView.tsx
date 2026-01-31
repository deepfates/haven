import { useState, useRef, useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import { currentSessionAtom, currentSessionIdAtom, connectionStatusAtom } from "../state/atoms";
import { ApprovalCard } from "./ApprovalCard";
import { ThemeSwitcher } from "./ThemeSwitcher";

interface SessionViewProps {
  onSendPrompt: (sessionId: string, text: string) => void;
  onRespondPermission: (sessionId: string, requestId: string | number, optionId: string) => void;
  onCancel: (sessionId: string) => void;
}

export function SessionView({ onSendPrompt, onRespondPermission, onCancel }: SessionViewProps) {
  const [session] = useAtom(currentSessionAtom);
  const setCurrentSessionId = useSetAtom(currentSessionIdAtom);
  const [connectionStatus] = useAtom(connectionStatusAtom);
  const [input, setInput] = useState("");
  const feedRef = useRef<HTMLDivElement>(null);
  const isDisconnected = connectionStatus !== "connected";

  // Auto-scroll on new messages
  useEffect(() => {
    if (feedRef.current) {
      feedRef.current.scrollTop = feedRef.current.scrollHeight;
    }
  }, [session?.messages]);

  if (!session) return null;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim()) return;

    onSendPrompt(session.id, input.trim());
    setInput("");
  };

  const planProgress = session.plan
    ? {
        current: session.plan.filter((e) => e.status === "completed").length,
        total: session.plan.length,
      }
    : null;

  return (
    <div className="flex flex-col h-dvh bg-base-100">
      {isDisconnected && (
        <div className="alert alert-warning rounded-none justify-center py-2">
          <span className="loading loading-spinner loading-sm" />
          <span>{connectionStatus === "connecting" ? "Reconnecting..." : "Disconnected"}</span>
        </div>
      )}

      <div className="navbar bg-base-200 border-b border-base-300 min-h-0 px-2">
        <div className="flex-none">
          <button
            className="btn btn-ghost btn-sm"
            onClick={() => setCurrentSessionId(null)}
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              strokeWidth={2}
              stroke="currentColor"
              className="w-5 h-5"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M15.75 19.5 8.25 12l7.5-7.5"
              />
            </svg>
          </button>
        </div>
        <div className="flex-1 min-w-0 px-2">
          <h2 className="font-semibold truncate">{session.title}</h2>
        </div>
        <div className="flex-none flex items-center gap-1">
          {isDisconnected && (
            <span
              className={`w-2 h-2 rounded-full ${
                connectionStatus === "connecting" ? "bg-warning" : "bg-error"
              }`}
            />
          )}
          <ThemeSwitcher />
          {session.status === "running" && !isDisconnected && (
            <button
              className="btn btn-ghost btn-sm text-error"
              onClick={() => onCancel(session.id)}
            >
              Stop
            </button>
          )}
        </div>
      </div>

      {planProgress && (
        <div className="px-4 py-2 bg-base-200 border-b border-base-300">
          <div className="flex items-center gap-3 text-sm">
            <span className="text-base-content/70">
              Step {planProgress.current + 1} of {planProgress.total}
            </span>
            <progress
              className="progress progress-primary flex-1"
              value={planProgress.current + 1}
              max={planProgress.total}
            />
          </div>
        </div>
      )}

      <div className="flex-1 overflow-y-auto p-4 space-y-4" ref={feedRef}>
        {session.messages.map((message) => {
          if (message.type === "tool") {
            return (
              <div key={message.id} className="flex items-start gap-2 text-sm">
                <span className="text-base-content/50">
                  {message.toolCall?.status === "completed" ? (
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      fill="none"
                      viewBox="0 0 24 24"
                      strokeWidth={2}
                      stroke="currentColor"
                      className="w-4 h-4 text-success"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        d="m4.5 12.75 6 6 9-13.5"
                      />
                    </svg>
                  ) : (
                    <span className="loading loading-spinner loading-xs" />
                  )}
                </span>
                <div className="flex-1">
                  <span className="text-base-content/70">{message.content}</span>
                  {message.toolCall?.fileLocations?.map((loc, i) => (
                    <div key={i} className="text-xs font-mono text-primary mt-1">
                      {loc.path}
                      {loc.line ? `:${loc.line}` : ""}
                    </div>
                  ))}
                </div>
              </div>
            );
          }

          return (
            <div
              key={message.id}
              className={`chat ${message.type === "user" ? "chat-end" : "chat-start"}`}
            >
              <div
                className={`chat-bubble ${
                  message.type === "user"
                    ? "chat-bubble-primary"
                    : "chat-bubble-neutral"
                } whitespace-pre-wrap`}
              >
                {message.content}
              </div>
            </div>
          );
        })}

        {session.pendingApproval && (
          <ApprovalCard
            request={session.pendingApproval}
            onRespond={(optionId) =>
              onRespondPermission(session.id, session.pendingApproval!.requestId, optionId)
            }
          />
        )}
      </div>

      <form
        className="flex gap-2 p-4 bg-base-200 border-t border-base-300"
        onSubmit={handleSubmit}
      >
        <input
          type="text"
          className="input input-bordered flex-1"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder={isDisconnected ? "Reconnecting..." : "Type to redirect..."}
          disabled={session.status === "waiting" || isDisconnected}
        />
        <button
          type="submit"
          className="btn btn-primary"
          disabled={!input.trim() || session.status === "waiting" || isDisconnected}
        >
          Send
        </button>
      </form>
    </div>
  );
}
