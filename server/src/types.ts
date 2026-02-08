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

export type JsonRpcMessage =
  | JsonRpcRequest
  | JsonRpcResponse
  | JsonRpcNotification;

// ACP-specific types

export interface SessionNewParams {
  sessionId?: string;
  cwd?: string;
}

export interface SessionPromptParams {
  sessionId: string;
  prompt: ContentBlock[];
}

export interface ContentBlock {
  type: "text" | "image" | "audio" | "resource_link" | "embedded_resource";
  text?: string;
  uri?: string;
  mimeType?: string;
  data?: string;
  [key: string]: unknown;
}

export interface SessionUpdate {
  sessionId: string;
  update: SessionUpdateType;
}

export type SessionUpdateType =
  | { sessionUpdate: "agent_message_chunk"; content: ContentBlock }
  | { sessionUpdate: "user_message_chunk"; content: ContentBlock }
  | { sessionUpdate: "agent_thought_chunk"; content: ContentBlock }
  | {
      sessionUpdate: "tool_call";
      toolCallId: string;
      title: string;
      kind?: ToolKind;
      status?: ToolCallStatus;
      locations?: ToolCallLocation[];
      rawInput?: unknown;
      rawOutput?: unknown;
    }
  | {
      sessionUpdate: "tool_call_update";
      toolCallId: string;
      title?: string;
      status?: ToolCallStatus;
      locations?: ToolCallLocation[];
      rawInput?: unknown;
      rawOutput?: unknown;
    }
  | { sessionUpdate: "plan"; entries: PlanEntry[] }
  | { sessionUpdate: "available_commands_update"; availableCommands: unknown[] }
  | { sessionUpdate: "current_mode_update"; currentModeId: string }
  | { sessionUpdate: "config_option_update"; configOptions: unknown[] }
  | {
      sessionUpdate: "session_info_update";
      title?: string;
      updatedAt?: string;
    };

export type ToolCallStatus = "pending" | "in_progress" | "completed" | "failed";

export type ToolKind =
  | "read"
  | "edit"
  | "delete"
  | "move"
  | "search"
  | "execute"
  | "think"
  | "fetch"
  | "switch_mode"
  | "other";

export interface ToolCallLocation {
  path: string;
  line?: number;
}

export interface PlanEntry {
  content: string;
  status: "pending" | "in_progress" | "completed";
  priority: "high" | "medium" | "low";
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
