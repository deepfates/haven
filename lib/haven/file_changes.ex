defmodule Haven.FileChanges do
  import Ecto.Query

  alias Haven.FileChanges.FileChange
  alias Haven.Repo

  def create_pending!(run_id, attrs) do
    attrs =
      attrs
      |> Map.put(:run_id, run_id)
      |> Map.put_new(:status, "pending")

    %FileChange{}
    |> FileChange.changeset(attrs)
    |> Repo.insert!()
  end

  def list_for_run(run_id) do
    Repo.all(
      from c in FileChange,
        where: c.run_id == ^run_id,
        order_by: [asc: c.inserted_at]
    )
  end

  def mark_applied!(run_id, change_id, resolved_path) do
    run_id
    |> get_change!(change_id)
    |> FileChange.changeset(%{status: "applied", resolved_path: resolved_path})
    |> Repo.update!()
  end

  def mark_denied!(run_id, change_id, error) do
    run_id
    |> get_change!(change_id)
    |> FileChange.changeset(%{status: "denied", error: error})
    |> Repo.update!()
  end

  def mark_failed!(run_id, change_id, error) do
    run_id
    |> get_change!(change_id)
    |> FileChange.changeset(%{status: "failed", error: error})
    |> Repo.update!()
  end

  def mark_cancelled!(run_id, change_id, error) do
    run_id
    |> get_change!(change_id)
    |> FileChange.changeset(%{status: "cancelled", error: error})
    |> Repo.update!()
  end

  defp get_change!(run_id, change_id) do
    Repo.get_by!(FileChange, run_id: run_id, change_id: change_id)
  end
end
