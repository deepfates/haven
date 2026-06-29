defmodule Haven.PermissionAudits do
  import Ecto.Query

  alias Haven.PermissionAudits.PermissionAudit
  alias Haven.Repo

  def create_pending!(run_id, kind, payload) do
    attrs =
      payload
      |> attrs_from_permission_payload()
      |> Map.merge(%{
        run_id: run_id,
        kind: Atom.to_string(kind),
        status: "pending"
      })

    %PermissionAudit{}
    |> PermissionAudit.changeset(attrs)
    |> Repo.insert!()
  end

  def list_for_run(run_id) do
    Repo.all(
      from a in PermissionAudit,
        where: a.run_id == ^run_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
  end

  def mark_resolved!(run_id, request_id, attrs) do
    case latest_pending(run_id, request_id) do
      nil ->
        nil

      audit ->
        status = if attrs["outcome"] == "cancelled", do: "cancelled", else: "resolved"

        audit
        |> PermissionAudit.changeset(%{
          status: status,
          selected_option_id: attrs["option_id"],
          outcome: attrs["outcome"],
          actor: attrs["actor"],
          reason: attrs["reason"],
          resolved_at: DateTime.utc_now(:microsecond)
        })
        |> Repo.update!()
    end
  end

  def record_ignored_resolution!(run_id, request_id, attrs) do
    %PermissionAudit{}
    |> PermissionAudit.changeset(%{
      run_id: run_id,
      request_id: request_id,
      kind: "resolution_attempt",
      status: "ignored",
      selected_option_id: attrs["option_id"],
      actor: attrs["actor"],
      reason: attrs["reason"],
      resolved_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.insert!()
  end

  defp latest_pending(run_id, request_id) do
    Repo.one(
      from a in PermissionAudit,
        where: a.run_id == ^run_id,
        where: a.request_id == ^request_id,
        where: a.status == "pending",
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: 1
    )
  end

  defp attrs_from_permission_payload(payload) do
    tool_call = payload["toolCall"] || %{}

    %{
      request_id: payload["request_id"],
      title: tool_call["title"],
      tool_call_id: tool_call["toolCallId"] || tool_call["id"],
      raw_input: tool_call["rawInput"] || %{},
      options: %{"items" => payload["options"] || []}
    }
  end
end
