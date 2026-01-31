import { useAtom, useSetAtom } from "jotai";
import { sessionListAtom, currentSessionIdAtom } from "../state/atoms";

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
}

export function Inbox({ onCreateSession }: InboxProps) {
  const [sessions] = useAtom(sessionListAtom);
  const setCurrentSessionId = useSetAtom(currentSessionIdAtom);

  return (
    <div className="p-4">
      {sessions.length === 0 ? (
        <div className="hero min-h-[60vh]">
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
              className="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer"
              onClick={() => setCurrentSessionId(session.id)}
            >
              <div className="card-body p-4 flex-row items-center gap-4">
                <div
                  className={`badge badge-lg ${getStatusBadge(
                    session.status,
                    !!session.pendingApproval
                  )}`}
                >
                  {session.status === "running" && !session.pendingApproval && (
                    <span className="loading loading-spinner loading-xs mr-1" />
                  )}
                  {session.pendingApproval ? "!" : ""}
                </div>
                <div className="flex-1 min-w-0">
                  <h3 className="font-semibold truncate">{session.title}</h3>
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
          ))}
        </div>
      )}
    </div>
  );
}
