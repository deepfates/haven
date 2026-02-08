import { useState, useRef, useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import Markdown from "react-markdown";
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

      <div className="flex-1 overflow-y-auto p-4" ref={feedRef}>
        <div className="max-w-3xl mx-auto space-y-4">
        {session.messages.length === 0 && (
          <div className="flex flex-col items-center justify-center h-full text-base-content/50">
            {session.status === "connecting" || session.status === "running" ? (
              <>
                <span className="loading loading-dots loading-lg mb-4" />
                <p>Agent is starting up...</p>
              </>
            ) : session.status === "error" ? (
              <>
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-12 h-12 text-error mb-4">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z" />
                </svg>
                <p>Session ended with an error</p>
              </>
            ) : (
              <p>No messages yet</p>
            )}
          </div>
        )}
        {session.messages.map((message) => {
          if (message.type === "tool") {
            const status = message.toolCall?.status;
            return (
              <div key={message.id} className="flex items-start gap-3 py-2 px-3 rounded-lg bg-base-200/50 text-sm">
                <div className="flex-shrink-0 mt-0.5">
                  {status === "completed" ? (
                    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4 text-success">
                      <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 12.75 6 6 9-13.5" />
                    </svg>
                  ) : status === "failed" ? (
                    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4 text-error">
                      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
                    </svg>
                  ) : (
                    <span className="loading loading-spinner loading-xs text-primary" />
                  )}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    {message.toolCall?.name && (
                      <span className="font-mono text-xs px-1.5 py-0.5 rounded bg-base-300 text-base-content/70">
                        {message.toolCall.name}
                      </span>
                    )}
                  </div>
                  <p className="text-base-content/80 mt-1">{message.content}</p>
                  {message.toolCall?.fileLocations?.map((loc, i) => (
                    <div key={i} className="font-mono text-xs text-primary mt-1 truncate">
                      {loc.path}{loc.line ? `:${loc.line}` : ""}
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
                {message.type === "agent" ? (
                  <Markdown
                    components={{
                      p: ({ children }) => <p className="mb-2 last:mb-0">{children}</p>,
                      ul: ({ children }) => <ul className="list-disc list-inside mb-2">{children}</ul>,
                      ol: ({ children }) => <ol className="list-decimal list-inside mb-2">{children}</ol>,
                      li: ({ children }) => <li className="ml-2">{children}</li>,
                      code: ({ children, className }) => {
                        const isBlock = className?.includes("language-");
                        return isBlock ? (
                          <pre className="bg-base-300 rounded p-2 my-2 overflow-x-auto text-sm">
                            <code>{children}</code>
                          </pre>
                        ) : (
                          <code className="bg-base-300 rounded px-1 text-sm">{children}</code>
                        );
                      },
                      strong: ({ children }) => <strong className="font-bold">{children}</strong>,
                    }}
                  >
                    {message.content}
                  </Markdown>
                ) : (
                  message.content
                )}
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
      </div>

      <div className="bg-base-200 border-t border-base-300 p-4">
        <form
          className="flex gap-2 max-w-3xl mx-auto"
          onSubmit={handleSubmit}
        >
          <input
            type="text"
            className="input input-bordered flex-1"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={isDisconnected ? "Reconnecting..." : "Send a message..."}
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
    </div>
  );
}
