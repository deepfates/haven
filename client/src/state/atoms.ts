import { atom } from "jotai";
import type { Session } from "../types/acp";

const STORAGE_KEY = "acp-sessions";
const SEQ_STORAGE_KEY = "acp-session-seqs";

// Serialize sessions to localStorage
function saveSessions(sessions: Map<string, Session>) {
  try {
    const data = Array.from(sessions.entries());
    localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
  } catch (e) {
    console.warn("[storage] Failed to save sessions:", e);
  }
}

// Load sessions from localStorage
function loadSessions(): Map<string, Session> {
  try {
    const data = localStorage.getItem(STORAGE_KEY);
    if (data) {
      const entries = JSON.parse(data) as [string, Session][];
      return new Map(entries);
    }
  } catch (e) {
    console.warn("[storage] Failed to load sessions:", e);
  }
  return new Map();
}

// Load/save sequence numbers per session
function loadSeqs(): Map<string, number> {
  try {
    const data = localStorage.getItem(SEQ_STORAGE_KEY);
    if (data) {
      return new Map(Object.entries(JSON.parse(data)));
    }
  } catch (e) {
    console.warn("[storage] Failed to load seqs:", e);
  }
  return new Map();
}

function saveSeq(sessionId: string, seq: number) {
  try {
    const seqs = loadSeqs();
    seqs.set(sessionId, seq);
    localStorage.setItem(SEQ_STORAGE_KEY, JSON.stringify(Object.fromEntries(seqs)));
  } catch (e) {
    console.warn("[storage] Failed to save seq:", e);
  }
}

export function getLastSeq(sessionId: string): number {
  return loadSeqs().get(sessionId) ?? -1;
}

export function updateLastSeq(sessionId: string, seq: number) {
  const current = getLastSeq(sessionId);
  if (seq > current) {
    saveSeq(sessionId, seq);
  }
}

// Connection state
export const connectionStatusAtom = atom<"disconnected" | "connecting" | "connected">("disconnected");

// Base sessions atom (internal)
const baseSessionsAtom = atom<Map<string, Session>>(loadSessions());

// All sessions - wraps base with localStorage sync
export const sessionsAtom = atom(
  (get) => get(baseSessionsAtom),
  (get, set, update: Map<string, Session> | ((prev: Map<string, Session>) => Map<string, Session>)) => {
    const newValue = typeof update === "function" ? update(get(baseSessionsAtom)) : update;
    set(baseSessionsAtom, newValue);
    saveSessions(newValue);
  }
);

// Currently selected session - persisted to localStorage
const CURRENT_SESSION_KEY = "acp-current-session";

const baseCurrentSessionIdAtom = atom<string | null>(
  localStorage.getItem(CURRENT_SESSION_KEY)
);

export const currentSessionIdAtom = atom(
  (get) => get(baseCurrentSessionIdAtom),
  (_get, set, newId: string | null) => {
    set(baseCurrentSessionIdAtom, newId);
    if (newId) {
      localStorage.setItem(CURRENT_SESSION_KEY, newId);
    } else {
      localStorage.removeItem(CURRENT_SESSION_KEY);
    }
  }
);

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

// Pending updates for sessions that don't exist yet (race condition fix)
const pendingUpdates = new Map<string, Partial<Session>[]>();

// Helper to update a session
export const updateSessionAtom = atom(
  null,
  (get, set, update: { id: string; changes: Partial<Session> }) => {
    const sessions = new Map(get(sessionsAtom));
    const session = sessions.get(update.id);
    if (session) {
      // Apply any pending updates first
      const pending = pendingUpdates.get(update.id) || [];
      pendingUpdates.delete(update.id);
      let updated = session;
      for (const p of pending) {
        updated = { ...updated, ...p };
      }
      updated = { ...updated, ...update.changes };
      sessions.set(update.id, updated);
      set(sessionsAtom, sessions);
    } else {
      // Queue for later - session might not exist in state yet
      const pending = pendingUpdates.get(update.id) || [];
      pending.push(update.changes);
      pendingUpdates.set(update.id, pending);
      // Retry after a short delay
      setTimeout(() => {
        const currentSessions = get(sessionsAtom);
        if (currentSessions.has(update.id) && pendingUpdates.has(update.id)) {
          const pending = pendingUpdates.get(update.id) || [];
          pendingUpdates.delete(update.id);
          const newSessions = new Map(currentSessions);
          let updated = newSessions.get(update.id)!;
          for (const p of pending) {
            updated = { ...updated, ...p };
          }
          newSessions.set(update.id, updated);
          set(sessionsAtom, newSessions);
        }
      }, 50);
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

// Helper to update a tool call message
export const updateToolCallAtom = atom(
  null,
  (get, set, payload: { sessionId: string; toolCallId: string; status?: string; locations?: { path: string; line?: number }[]; rawOutput?: unknown }) => {
    const sessions = new Map(get(sessionsAtom));
    const session = sessions.get(payload.sessionId);
    if (!session) return;

    const messages = session.messages.map((m) => {
      if (m.id === payload.toolCallId && m.toolCall) {
        return {
          ...m,
          toolCall: {
            ...m.toolCall,
            status: (payload.status as "pending" | "running" | "completed" | "failed") || m.toolCall.status,
            fileLocations: payload.locations || m.toolCall.fileLocations,
            rawOutput: payload.rawOutput ?? m.toolCall.rawOutput,
          },
        };
      }
      return m;
    });

    sessions.set(payload.sessionId, { ...session, messages });
    set(sessionsAtom, sessions);
  }
);

// Helper to append to the last agent message (for streaming)
// Creates a new message if there's no agent message to append to
export const appendToLastMessageAtom = atom(
  null,
  (get, set, payload: { sessionId: string; content: string }) => {
    const sessions = new Map(get(sessionsAtom));
    const session = sessions.get(payload.sessionId);
    if (!session) return;

    const messages = [...session.messages];
    const last = messages[messages.length - 1];

    if (last?.type === "agent") {
      // Append to existing agent message
      messages[messages.length - 1] = {
        ...last,
        content: last.content + payload.content,
      };
    } else {
      // Create new agent message
      messages.push({
        id: `msg_${Date.now()}`,
        type: "agent",
        content: payload.content,
        timestamp: Date.now(),
      });
    }

    sessions.set(payload.sessionId, { ...session, messages });
    set(sessionsAtom, sessions);
  }
);
