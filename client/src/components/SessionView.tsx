import { useState, useRef, useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import { currentSessionAtom, currentSessionIdAtom, connectionStatusAtom } from "../state/atoms";
import { ApprovalCard } from "./ApprovalCard";

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
    <div className="session-view">
      {isDisconnected && (
        <div className="reconnecting-banner">
          {connectionStatus === "connecting" ? "Reconnecting..." : "Disconnected"}
        </div>
      )}
      <div className="session-header">
        <button className="back-button icon" onClick={() => setCurrentSessionId(null)}>
          ←
        </button>
        <h2>{session.title}</h2>
        <div className="header-right">
          {isDisconnected && (
            <span className={`status-dot ${connectionStatus}`} title={connectionStatus} />
          )}
          {session.status === "running" && !isDisconnected && (
            <button className="secondary" onClick={() => onCancel(session.id)}>
              Stop
            </button>
          )}
        </div>
      </div>

      {planProgress && (
        <div className="progress">
          <span>Step {planProgress.current + 1} of {planProgress.total}</span>
          <div className="progress-bar">
            <div
              className="progress-fill"
              style={{ width: `${((planProgress.current + 1) / planProgress.total) * 100}%` }}
            />
          </div>
        </div>
      )}

      <div className="activity-feed" ref={feedRef}>
        {session.messages.map((message) => {
          if (message.type === "tool") {
            return (
              <div key={message.id} className="message tool">
                <span className="tool-icon">
                  {message.toolCall?.status === "completed" ? "✓" : "⚙️"}
                </span>
                <span>{message.content}</span>
                {message.toolCall?.fileLocations?.map((loc, i) => (
                  <div key={i} className="file-location">
                    📄 {loc.path}{loc.line ? `:${loc.line}` : ""}
                  </div>
                ))}
              </div>
            );
          }

          return (
            <div key={message.id} className={`message ${message.type}`}>
              <div className="message-content">{message.content}</div>
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

      <form className="input-area" onSubmit={handleSubmit}>
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder={isDisconnected ? "Reconnecting..." : "Type to redirect..."}
          disabled={session.status === "waiting" || isDisconnected}
        />
        <button type="submit" disabled={!input.trim() || session.status === "waiting" || isDisconnected}>
          Send
        </button>
      </form>
    </div>
  );
}
