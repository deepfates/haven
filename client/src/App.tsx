import { useState, useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import { currentSessionIdAtom, connectionStatusAtom } from "./state/atoms";
import { useAcpConnection } from "./hooks/useAcpConnection";
import { Inbox } from "./components/Inbox";
import { SessionView } from "./components/SessionView";
import { ThemeSwitcher } from "./components/ThemeSwitcher";
import "./styles.css";

export default function App() {
  const [currentSessionId] = useAtom(currentSessionIdAtom);
  const setCurrentSessionId = useSetAtom(currentSessionIdAtom);
  const [connectionStatus] = useAtom(connectionStatusAtom);
  const { createSession, sendPrompt, respondToPermission, cancelSession, loadSession } = useAcpConnection();
  const [isCreating, setIsCreating] = useState(false);

  // Load session data and subscribe to push notifications when a session is selected
  useEffect(() => {
    if (currentSessionId && connectionStatus === "connected") {
      loadSession(currentSessionId).catch((err) => {
        console.error("[App] Failed to load session:", err);
      });
    }
  }, [currentSessionId, connectionStatus, loadSession]);

  const handleCreateSession = async () => {
    if (isCreating) return;
    setIsCreating(true);

    try {
      const title = `Task ${new Date().toLocaleTimeString()}`;
      const sessionId = await createSession(title);
      // Navigate to the new session immediately
      setCurrentSessionId(sessionId);
    } catch (err) {
      console.error("Failed to create session:", err);
    } finally {
      setIsCreating(false);
    }
  };

  // Show session view if one is selected
  if (currentSessionId) {
    return (
      <SessionView
        onSendPrompt={sendPrompt}
        onRespondPermission={respondToPermission}
        onCancel={cancelSession}
      />
    );
  }

  // Show inbox
  return (
    <div className="flex flex-col h-dvh bg-base-100">
      <header className="navbar bg-base-200 border-b border-base-300 px-4">
        <div className="flex-1">
          <h1 className="text-xl font-bold">Agents</h1>
        </div>
        <div className="flex-none flex items-center gap-2">
          <div className="flex items-center gap-2 text-sm opacity-70">
            <span
              className={`w-2 h-2 rounded-full ${
                connectionStatus === "connected"
                  ? "bg-success"
                  : connectionStatus === "connecting"
                  ? "bg-warning"
                  : "bg-error"
              }`}
            />
            <span className="hidden sm:inline">{connectionStatus}</span>
          </div>
          <ThemeSwitcher />
          <button
            className="btn btn-primary btn-sm"
            onClick={handleCreateSession}
            disabled={isCreating || connectionStatus !== "connected"}
          >
            {isCreating ? (
              <span className="loading loading-spinner loading-xs" />
            ) : (
              "+ New"
            )}
          </button>
        </div>
      </header>
      <main className="flex-1 overflow-y-auto">
        <Inbox onCreateSession={handleCreateSession} />
      </main>
    </div>
  );
}
