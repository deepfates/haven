import { useAtom, useSetAtom } from "jotai";
import { sessionListAtom, currentSessionIdAtom } from "../state/atoms";

function getStatusBadge(status: string, hasPendingApproval: boolean) {
  if (hasPendingApproval) return "🔴";
  switch (status) {
    case "running":
      return "🟢";
    case "waiting":
      return "🟡";
    case "completed":
      return "✅";
    case "error":
      return "❌";
    default:
      return "⚪";
  }
}

function getStatusText(status: string, hasPendingApproval: boolean) {
  if (hasPendingApproval) return "Needs approval";
  switch (status) {
    case "running":
      return "Running...";
    case "waiting":
      return "Waiting";
    case "completed":
      return "Completed";
    case "error":
      return "Error";
    default:
      return status;
  }
}

interface InboxProps {
  onCreateSession: () => void;
}

export function Inbox({ onCreateSession }: InboxProps) {
  const [sessions] = useAtom(sessionListAtom);
  const setCurrentSessionId = useSetAtom(currentSessionIdAtom);

  return (
    <div className="inbox">
      {sessions.length === 0 ? (
        <div className="empty-state">
          <h3>No agents yet</h3>
          <p>Create a new session to get started</p>
          <button onClick={onCreateSession} style={{ marginTop: 16 }}>
            + New Agent
          </button>
        </div>
      ) : (
        sessions.map((session) => (
          <div
            key={session.id}
            className="session-card"
            onClick={() => setCurrentSessionId(session.id)}
          >
            <span className="session-badge">
              {getStatusBadge(session.status, !!session.pendingApproval)}
            </span>
            <div className="session-info">
              <div className="session-title">{session.title}</div>
              <div className={`session-status ${session.pendingApproval ? "waiting" : ""}`}>
                {getStatusText(session.status, !!session.pendingApproval)}
              </div>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
