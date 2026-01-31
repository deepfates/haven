// ACP message types (shared with server, could be a shared package)

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
  _sessionId?: string; // Added by bridge
}

export type JsonRpcMessage = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification;

// Session types

export interface Session {
  id: string;
  status: "connecting" | "running" | "waiting" | "completed" | "error";
  title: string;
  messages: SessionMessage[];
  plan?: PlanEntry[];
  pendingApproval?: PermissionRequest;
}

export interface SessionMessage {
  id: string;
  type: "user" | "agent" | "tool" | "system";
  content: string;
  timestamp: number;
  toolCall?: ToolCall;
}

export interface ToolCall {
  id: string;
  name: string;
  status: "pending" | "running" | "completed" | "failed";
  fileLocations?: FileLocation[];
  rawOutput?: unknown;
}

export interface FileLocation {
  path: string;
  line?: number;
}

export interface PlanEntry {
  id: string;
  title: string;
  status: "pending" | "in_progress" | "completed";
}

export interface PermissionOption {
  optionId: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always";
}

export interface PermissionRequest {
  requestId: string | number; // The JSON-RPC request ID for responding
  id: string; // Tool call ID
  toolName: string;
  input: unknown;
  options: PermissionOption[];
}
