import { useAtom, useSetAtom } from "jotai";
import { formatDistanceToNow } from "date-fns";
import { sessionListAtom, currentSessionIdAtom } from "../state/atoms";
import type { Session } from "../types/acp";

function getLastActivityTime(session: Session): string | null {
  if (session.messages.length === 0) return null;
  const lastMessage = session.messages[session.messages.length - 1];
  if (!lastMessage.timestamp) return null;
  return formatDistanceToNow(lastMessage.timestamp, { addSuffix: true });
}

function getStatusBadge(status: string, hasPendingApproval: boolean) {
  if (hasPendingApproval) return "badge-error";
  switch (status) {
    case "running":
      return "badge-success";
    case "waiting":
      return "badge-warning";
    case "completed":
      return "badge-info";
    case "error":
      return "badge-error";
    default:
      return "badge-ghost";
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
  onArchiveSession?: (sessionId: string) => void;
}

export function Inbox({ onCreateSession, onArchiveSession }: InboxProps) {
  const [sessions] = useAtom(sessionListAtom);
  const setCurrentSessionId = useSetAtom(currentSessionIdAtom);

  return (
    <div className="p-4 max-w-2xl mx-auto">
      {sessions.length === 0 ? (
        <div className="hero min-h-[50vh]">
          <div className="hero-content text-center">
            <div className="max-w-md">
              <h2 className="text-2xl font-bold mb-2">No agents yet</h2>
              <p className="text-base-content/70 mb-6">
                Create a new session to get started
              </p>
              <button className="btn btn-primary" onClick={onCreateSession}>
                + New Agent
              </button>
            </div>
          </div>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          {sessions.map((session) => (
            <div
              key={session.id}
              className="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer active:scale-[0.98] group"
              onClick={() => setCurrentSessionId(session.id)}
            >
              <div className="card-body p-4 flex-row items-center gap-3">
                <div className="flex-shrink-0">
                  {session.pendingApproval ? (
                    <div className="w-10 h-10 rounded-full bg-warning/20 flex items-center justify-center">
                      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5 text-warning">
                        <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z" />
                      </svg>
                    </div>
                  ) : session.status === "running" ? (
                    <div className="w-10 h-10 rounded-full bg-success/20 flex items-center justify-center">
                      <span className="loading loading-spinner loading-sm text-success" />
                    </div>
                  ) : session.status === "error" ? (
                    <div className="w-10 h-10 rounded-full bg-error/20 flex items-center justify-center">
                      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5 text-error">
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
                      </svg>
                    </div>
                  ) : session.status === "completed" ? (
                    <div className="w-10 h-10 rounded-full bg-info/20 flex items-center justify-center">
                      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5 text-info">
                        <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 12.75 6 6 9-13.5" />
                      </svg>
                    </div>
                  ) : (
                    <div className="w-10 h-10 rounded-full bg-base-300 flex items-center justify-center">
                      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5 text-base-content/50">
                        <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
                      </svg>
                    </div>
                  )}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <h3 className="font-semibold truncate">{session.title}</h3>
                    {(() => {
                      const time = getLastActivityTime(session);
                      return time ? (
                        <span className="text-xs text-base-content/40 flex-shrink-0">{time}</span>
                      ) : null;
                    })()}
                  </div>
                  <p
                    className={`text-sm ${
                      session.pendingApproval
                        ? "text-warning"
                        : "text-base-content/60"
                    }`}
                  >
                    {getStatusText(session.status, !!session.pendingApproval)}
                  </p>
                </div>
                <div className="flex items-center gap-1 flex-shrink-0">
                  {onArchiveSession && (session.status === "error" || session.status === "completed") && (
                    <button
                      className="btn btn-ghost btn-sm btn-square opacity-60 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity"
                      onClick={(e) => {
                        e.stopPropagation();
                        onArchiveSession(session.id);
                      }}
                      title="Delete session"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-4 h-4 text-base-content/50 hover:text-error transition-colors">
                        <path strokeLinecap="round" strokeLinejoin="round" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0" />
                      </svg>
                    </button>
                  )}
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    strokeWidth={2}
                    stroke="currentColor"
                    className="w-5 h-5 opacity-40"
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      d="m8.25 4.5 7.5 7.5-7.5 7.5"
                    />
                  </svg>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
