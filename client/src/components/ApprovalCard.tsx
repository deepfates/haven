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
      <div className="card bg-warning/10 border border-warning">
        <div className="card-body p-4">
          <h4 className="card-title text-warning text-sm">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              strokeWidth={2}
              stroke="currentColor"
              className="w-5 h-5"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z"
              />
            </svg>
            Approval Needed
          </h4>
          <p className="font-semibold">{request.toolName}</p>
          <div className="mockup-code bg-base-300 text-xs overflow-x-auto">
            <pre className="px-4"><code>{inputStr}</code></pre>
          </div>
          <p className="text-sm text-base-content/60">No options available</p>
        </div>
      </div>
    );
  }

  return (
    <div className="card bg-warning/10 border border-warning">
      <div className="card-body p-4">
        <h4 className="card-title text-warning text-sm">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            strokeWidth={2}
            stroke="currentColor"
            className="w-5 h-5"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z"
            />
          </svg>
          Approval Needed
        </h4>
        <p className="font-semibold">{request.toolName}</p>
        <div className="mockup-code bg-base-300 text-xs overflow-x-auto">
          <pre className="px-4"><code>{inputStr}</code></pre>
        </div>
        <div className="card-actions justify-end mt-2">
          {allowOptions.map(option => (
            <button
              key={option.optionId}
              className="btn btn-success btn-sm"
              onClick={() => onRespond(option.optionId)}
            >
              {option.name}
            </button>
          ))}
          {rejectOptions.map(option => (
            <button
              key={option.optionId}
              className="btn btn-error btn-sm"
              onClick={() => onRespond(option.optionId)}
            >
              {option.name}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
