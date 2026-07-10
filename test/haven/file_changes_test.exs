defmodule Haven.FileChangesTest do
  use Haven.DataCase, async: true

  alias Haven.Events
  alias Haven.FileChanges
  alias Haven.Repo
  alias Haven.Runs.Run

  test "tracks a proposed file change through applied status" do
    run = insert_run!()

    change =
      FileChanges.create_pending!(run.id, %{
        change_id: "file-write-1",
        path: "notes/handoff.md",
        diff_kind: "create",
        bytes: 12,
        existing_bytes: 0,
        content_preview: "hello world\n",
        content_preview_limit: 4_000,
        content_truncated: false,
        diff_preview: "--- /dev/null\n+++ notes/handoff.md\n+hello world\n",
        diff_preview_limit: 8_000,
        diff_truncated: false
      })

    assert change.status == "pending"

    applied = FileChanges.mark_applied!(run.id, "file-write-1", "/workspace/notes/handoff.md")

    assert applied.status == "applied"
    assert applied.resolved_path == "/workspace/notes/handoff.md"
    assert [^applied] = FileChanges.list_for_run(run.id)
  end

  test "tracks denied, failed, and cancelled file changes" do
    run = insert_run!()
    error = %{"message" => "Permission denied", "data" => %{"reason" => "permission_denied"}}

    FileChanges.create_pending!(run.id, base_attrs("denied"))
    FileChanges.create_pending!(run.id, base_attrs("failed"))
    FileChanges.create_pending!(run.id, base_attrs("cancelled"))

    denied = FileChanges.mark_denied!(run.id, "denied", error)
    failed = FileChanges.mark_failed!(run.id, "failed", error)
    cancelled = FileChanges.mark_cancelled!(run.id, "cancelled", error)

    assert denied.status == "denied"
    assert failed.status == "failed"
    assert cancelled.status == "cancelled"

    assert FileChanges.list_for_run(run.id) |> Enum.map(& &1.status) |> Enum.sort() == [
             "cancelled",
             "denied",
             "failed"
           ]
  end

  defp base_attrs(change_id) do
    %{
      change_id: change_id,
      path: "#{change_id}.txt",
      diff_kind: "create",
      bytes: 4,
      content_preview: "test",
      diff_preview: "--- /dev/null\n+++ #{change_id}.txt\n+test\n"
    }
  end

  defp insert_run! do
    run =
      %Run{}
      |> Run.changeset(%{
        title: "File changes run",
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: "idle"
      })
      |> Repo.insert!()

    Events.append!(run.id, "run_created", %{
      "title" => run.title,
      "workspace" => run.workspace,
      "agent" => run.agent
    })

    run
  end
end
