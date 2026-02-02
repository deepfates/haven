import { useState, useEffect, useRef } from "react";
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
  const { createSession, sendPrompt, respondToPermission, cancelSession, archiveSession, loadSession } = useAcpConnection();
  const [isCreating, setIsCreating] = useState(false);
  const [showNewModal, setShowNewModal] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  const titleInputRef = useRef<HTMLInputElement>(null);

  // Load session data and subscribe to push notifications when a session is selected
  useEffect(() => {
    if (currentSessionId && connectionStatus === "connected") {
      loadSession(currentSessionId).catch((err) => {
        console.error("[App] Failed to load session:", err);
      });
    }
  }, [currentSessionId, connectionStatus, loadSession]);

  const openNewModal = () => {
    setNewTitle("");
    setShowNewModal(true);
    setTimeout(() => titleInputRef.current?.focus(), 100);
  };

  const handleCreateSession = async (title?: string) => {
    if (isCreating) return;
    setIsCreating(true);
    setShowNewModal(false);

    try {
      const sessionTitle = title?.trim() || `New conversation`;
      const sessionId = await createSession(sessionTitle);
      setCurrentSessionId(sessionId);
    } catch (err) {
      console.error("Failed to create session:", err);
    } finally {
      setIsCreating(false);
      setNewTitle("");
    }
  };

  const handleModalSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    handleCreateSession(newTitle);
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
            onClick={openNewModal}
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
        <Inbox onCreateSession={openNewModal} onArchiveSession={archiveSession} />
      </main>

      {/* New Session Modal */}
      <dialog className={`modal ${showNewModal ? "modal-open" : ""}`}>
        <div className="modal-box">
          <h3 className="font-bold text-lg mb-4">New Conversation</h3>
          <form onSubmit={handleModalSubmit}>
            <input
              ref={titleInputRef}
              type="text"
              className="input input-bordered w-full"
              placeholder="What would you like to work on?"
              value={newTitle}
              onChange={(e) => setNewTitle(e.target.value)}
              autoFocus
            />
            <div className="modal-action">
              <button
                type="button"
                className="btn btn-ghost"
                onClick={() => setShowNewModal(false)}
              >
                Cancel
              </button>
              <button type="submit" className="btn btn-primary" disabled={isCreating}>
                {isCreating ? <span className="loading loading-spinner loading-xs" /> : "Create"}
              </button>
            </div>
          </form>
        </div>
        <form method="dialog" className="modal-backdrop">
          <button onClick={() => setShowNewModal(false)}>close</button>
        </form>
      </dialog>
    </div>
  );
}
