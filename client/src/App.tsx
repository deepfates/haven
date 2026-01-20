import { useState } from "react";
import { useAtom } from "jotai";
import { currentSessionIdAtom, connectionStatusAtom } from "./state/atoms";
import { useAcpConnection } from "./hooks/useAcpConnection";
import { Inbox } from "./components/Inbox";
import { SessionView } from "./components/SessionView";
import "./styles.css";

export default function App() {
  const [currentSessionId] = useAtom(currentSessionIdAtom);
  const [connectionStatus] = useAtom(connectionStatusAtom);
  const { createSession, sendPrompt, respondToPermission, cancelSession } = useAcpConnection();
  const [isCreating, setIsCreating] = useState(false);

  const handleCreateSession = async () => {
    if (isCreating) return;
    setIsCreating(true);

    try {
      const title = `Task ${new Date().toLocaleTimeString()}`;
      await createSession(title);
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
    <div className="app">
      <header className="header">
        <h1>Agents</h1>
        <div className="header-actions">
          <div className="status">
            <span className={`status-dot ${connectionStatus}`} />
            <span>{connectionStatus}</span>
          </div>
          <button onClick={handleCreateSession} disabled={isCreating || connectionStatus !== "connected"}>
            {isCreating ? "..." : "+ New"}
          </button>
        </div>
      </header>
      <main className="main">
        <Inbox onCreateSession={handleCreateSession} />
      </main>
    </div>
  );
}
