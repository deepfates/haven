import { atom } from "jotai";
import type { Session } from "../types/acp";

// Connection state
export const connectionStatusAtom = atom<"disconnected" | "connecting" | "connected">("disconnected");

// All sessions
export const sessionsAtom = atom<Map<string, Session>>(new Map());

// Currently selected session
export const currentSessionIdAtom = atom<string | null>(null);

// Derived: current session
export const currentSessionAtom = atom((get) => {
  const id = get(currentSessionIdAtom);
  if (!id) return null;
  return get(sessionsAtom).get(id) || null;
});

// Derived: sessions list sorted by most recent activity
export const sessionListAtom = atom((get) => {
  const sessions = get(sessionsAtom);
  return Array.from(sessions.values()).sort((a, b) => {
    const aLast = a.messages[a.messages.length - 1]?.timestamp || 0;
    const bLast = b.messages[b.messages.length - 1]?.timestamp || 0;
    return bLast - aLast;
  });
});

// Derived: sessions needing attention
export const sessionsNeedingAttentionAtom = atom((get) => {
  const sessions = get(sessionsAtom);
  return Array.from(sessions.values()).filter(
    (s) => s.pendingApproval || s.status === "error"
  );
});

// Helper to update a session
export const updateSessionAtom = atom(
  null,
  (get, set, update: { id: string; changes: Partial<Session> }) => {
    const sessions = new Map(get(sessionsAtom));
    const session = sessions.get(update.id);
    if (session) {
      sessions.set(update.id, { ...session, ...update.changes });
      set(sessionsAtom, sessions);
    }
  }
);

// Helper to add a message to a session
export const addMessageAtom = atom(
  null,
  (get, set, payload: { sessionId: string; message: Session["messages"][0] }) => {
    const sessions = new Map(get(sessionsAtom));
    const session = sessions.get(payload.sessionId);
    if (session) {
      sessions.set(payload.sessionId, {
        ...session,
        messages: [...session.messages, payload.message],
      });
      set(sessionsAtom, sessions);
    }
  }
);

// Helper to append to the last agent message (for streaming)
export const appendToLastMessageAtom = atom(
  null,
  (get, set, payload: { sessionId: string; content: string }) => {
    const sessions = new Map(get(sessionsAtom));
    const session = sessions.get(payload.sessionId);
    if (session && session.messages.length > 0) {
      const messages = [...session.messages];
      const last = messages[messages.length - 1];
      if (last.type === "agent") {
        messages[messages.length - 1] = {
          ...last,
          content: last.content + payload.content,
        };
        sessions.set(payload.sessionId, { ...session, messages });
        set(sessionsAtom, sessions);
      }
    }
  }
);
