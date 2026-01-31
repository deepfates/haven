import { Database } from "bun:sqlite";
import { join } from "path";
import { mkdirSync } from "fs";

// Store DB in ~/.acp-client/
const DATA_DIR = join(process.env.HOME || "/tmp", ".acp-client");
mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(join(DATA_DIR, "sessions.db"));

// Enable WAL mode for better concurrency
db.run("PRAGMA journal_mode = WAL");

// Create tables
db.run(`
  CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    agent_type TEXT NOT NULL,
    agent_session_id TEXT,
    cwd TEXT NOT NULL,
    title TEXT,
    status TEXT NOT NULL DEFAULT 'initializing',
    exit_reason TEXT,
    archived INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  )
`);

db.run(`
  CREATE TABLE IF NOT EXISTS updates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    update_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    UNIQUE(session_id, seq)
  )
`);

db.run(`
  CREATE TABLE IF NOT EXISTS pending_requests (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    request_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (session_id) REFERENCES sessions(id)
  )
`);

// Create indexes
db.run("CREATE INDEX IF NOT EXISTS idx_updates_session ON updates(session_id, seq)");
db.run("CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status)");
db.run("CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived)");

// Prepared statements
const insertSession = db.prepare(`
  INSERT INTO sessions (id, agent_type, cwd, title, status)
  VALUES (?, ?, ?, ?, ?)
`);

const updateSessionStatus = db.prepare(`
  UPDATE sessions SET status = ?, updated_at = datetime('now') WHERE id = ?
`);

const updateSessionAgentId = db.prepare(`
  UPDATE sessions SET agent_session_id = ?, updated_at = datetime('now') WHERE id = ?
`);

const updateSessionTitle = db.prepare(`
  UPDATE sessions SET title = ?, updated_at = datetime('now') WHERE id = ?
`);

const updateSessionExit = db.prepare(`
  UPDATE sessions SET status = 'exited', exit_reason = ?, updated_at = datetime('now') WHERE id = ?
`);

const archiveSession = db.prepare(`
  UPDATE sessions SET archived = 1, updated_at = datetime('now') WHERE id = ?
`);

const getSession = db.prepare(`
  SELECT * FROM sessions WHERE id = ?
`);

const listSessions = db.prepare(`
  SELECT * FROM sessions WHERE archived = ? ORDER BY updated_at DESC
`);

const listSessionsByStatus = db.prepare(`
  SELECT * FROM sessions WHERE archived = ? AND status IN (SELECT value FROM json_each(?)) ORDER BY updated_at DESC
`);

const insertUpdate = db.prepare(`
  INSERT INTO updates (session_id, seq, update_type, payload)
  VALUES (?, ?, ?, ?)
`);

const getUpdates = db.prepare(`
  SELECT * FROM updates WHERE session_id = ? ORDER BY seq
`);

const getUpdatesSince = db.prepare(`
  SELECT * FROM updates WHERE session_id = ? AND seq > ? ORDER BY seq
`);

const getLastSeq = db.prepare(`
  SELECT MAX(seq) as last_seq FROM updates WHERE session_id = ?
`);

const insertPendingRequest = db.prepare(`
  INSERT INTO pending_requests (id, session_id, request_id, request_type, payload)
  VALUES (?, ?, ?, ?, ?)
`);

const getPendingRequest = db.prepare(`
  SELECT * FROM pending_requests WHERE session_id = ? AND request_id = ?
`);

const deletePendingRequest = db.prepare(`
  DELETE FROM pending_requests WHERE session_id = ? AND request_id = ?
`);

const getPendingRequestsForSession = db.prepare(`
  SELECT * FROM pending_requests WHERE session_id = ?
`);

// Export functions
export interface Session {
  id: string;
  agent_type: string;
  agent_session_id: string | null;
  cwd: string;
  title: string | null;
  status: string;
  exit_reason: string | null;
  archived: number;
  created_at: string;
  updated_at: string;
}

export interface Update {
  id: number;
  session_id: string;
  seq: number;
  update_type: string;
  payload: string;
  created_at: string;
}

export interface PendingRequest {
  id: string;
  session_id: string;
  request_id: string;
  request_type: string;
  payload: string;
  created_at: string;
}

export const sessions = {
  create(id: string, agentType: string, cwd: string, title?: string): void {
    insertSession.run(id, agentType, cwd, title || null, "initializing");
  },

  get(id: string): Session | null {
    return getSession.get(id) as Session | null;
  },

  list(archived = false, statuses?: string[]): Session[] {
    if (statuses && statuses.length > 0) {
      return listSessionsByStatus.all(archived ? 1 : 0, JSON.stringify(statuses)) as Session[];
    }
    return listSessions.all(archived ? 1 : 0) as Session[];
  },

  setAgentSessionId(id: string, agentSessionId: string): void {
    updateSessionAgentId.run(agentSessionId, id);
  },

  setStatus(id: string, status: string): void {
    updateSessionStatus.run(status, id);
  },

  setTitle(id: string, title: string): void {
    updateSessionTitle.run(title, id);
  },

  setExited(id: string, reason: string): void {
    updateSessionExit.run(reason, id);
  },

  archive(id: string): void {
    archiveSession.run(id);
  },
};

export const updates = {
  add(sessionId: string, seq: number, updateType: string, payload: object): void {
    insertUpdate.run(sessionId, seq, updateType, JSON.stringify(payload));
  },

  list(sessionId: string): Update[] {
    return getUpdates.all(sessionId) as Update[];
  },

  listSince(sessionId: string, afterSeq: number): Update[] {
    return getUpdatesSince.all(sessionId, afterSeq) as Update[];
  },

  getLastSeq(sessionId: string): number {
    const result = getLastSeq.get(sessionId) as { last_seq: number | null };
    return result?.last_seq ?? 0;
  },
};

export const pendingRequests = {
  add(id: string, sessionId: string, requestId: string, requestType: string, payload: object): void {
    insertPendingRequest.run(id, sessionId, requestId, requestType, JSON.stringify(payload));
  },

  get(sessionId: string, requestId: string): PendingRequest | null {
    return getPendingRequest.get(sessionId, requestId) as PendingRequest | null;
  },

  delete(sessionId: string, requestId: string): void {
    deletePendingRequest.run(sessionId, requestId);
  },

  listForSession(sessionId: string): PendingRequest[] {
    return getPendingRequestsForSession.all(sessionId) as PendingRequest[];
  },
};

export default db;
