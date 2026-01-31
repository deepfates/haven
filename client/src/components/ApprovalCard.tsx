import type { PermissionRequest } from "../types/acp";

interface ApprovalCardProps {
  request: PermissionRequest;
  onRespond: (optionId: string) => void;
}

export function ApprovalCard({ request, onRespond }: ApprovalCardProps) {
  const inputStr = typeof request.input === "string"
    ? request.input
    : JSON.stringify(request.input, null, 2);

  // Group options by allow/reject
  const allowOptions = request.options?.filter(o => o.kind.startsWith("allow")) || [];
  const rejectOptions = request.options?.filter(o => o.kind.startsWith("reject")) || [];

  // Fallback if no options provided
  if (!request.options || request.options.length === 0) {
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
          <span className="muted">No options available</span>
        </div>
      </div>
    );
  }

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
        {allowOptions.map(option => (
          <button
            key={option.optionId}
            className="success"
            onClick={() => onRespond(option.optionId)}
          >
            {option.name}
          </button>
        ))}
        {rejectOptions.map(option => (
          <button
            key={option.optionId}
            className="danger"
            onClick={() => onRespond(option.optionId)}
          >
            {option.name}
          </button>
        ))}
      </div>
    </div>
  );
}
