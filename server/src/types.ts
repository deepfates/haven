// ACP JSON-RPC message types

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string | number;
  method: string;
  params?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: string | number;
  result?: unknown;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export type JsonRpcMessage = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification;

// ACP-specific types

export interface SessionNewParams {
  sessionId?: string;
  cwd?: string;
}

export interface SessionPromptParams {
  sessionId: string;
  content: ContentPart[];
}

export interface ContentPart {
  type: "text" | "image" | "resource";
  text?: string;
  uri?: string;
  mimeType?: string;
  data?: string;
}

export interface SessionUpdate {
  sessionId: string;
  update: SessionUpdateType;
}

export type SessionUpdateType =
  | { type: "agent_message_chunk"; content: string }
  | { type: "tool_call"; id: string; name: string; status: ToolStatus; fileLocations?: FileLocation[] }
  | { type: "tool_call_update"; id: string; status: ToolStatus; content?: string; fileLocations?: FileLocation[] }
  | { type: "plan"; entries: PlanEntry[] }
  | { type: "request_permission"; id: string; toolName: string; input: unknown };

export type ToolStatus = "pending" | "running" | "completed" | "failed";

export interface FileLocation {
  path: string;
  line?: number;
}

export interface PlanEntry {
  id: string;
  title: string;
  status: "pending" | "in_progress" | "completed";
}

// Bridge-specific types

export interface Session {
  id: string;
  agentProcess: ReturnType<typeof Bun.spawn> | null;
  cwd: string;
}

export interface BridgeConfig {
  port: number;
  host: string;
  agentCommand: string;
  defaultCwd: string;
}
