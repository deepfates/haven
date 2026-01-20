import type { PermissionRequest } from "../types/acp";

interface ApprovalCardProps {
  request: PermissionRequest;
  onRespond: (allow: boolean) => void;
}

export function ApprovalCard({ request, onRespond }: ApprovalCardProps) {
  const inputStr = typeof request.input === "string"
    ? request.input
    : JSON.stringify(request.input, null, 2);

  return (
    <div className="approval-card">
      <h4>⚠️ Approval Needed</h4>
      <p style={{ marginBottom: 8 }}>
        <strong>{request.toolName}</strong>
      </p>
      <div className="approval-content">
        <pre>{inputStr}</pre>
      </div>
      <div className="approval-actions">
        <button className="success" onClick={() => onRespond(true)}>
          Allow
        </button>
        <button className="danger" onClick={() => onRespond(false)}>
          Deny
        </button>
      </div>
    </div>
  );
}
