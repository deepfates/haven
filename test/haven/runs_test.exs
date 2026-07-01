defmodule Haven.RunsTest do
  use Haven.DataCase

  alias Haven.Events
  alias Haven.Repo
  alias Haven.Runs
  alias Haven.Runs.Run

  test "create_run rejects a missing workspace without starting a run" do
    missing_workspace = Path.join(System.tmp_dir!(), "haven-missing-workspace")
    File.rm_rf!(missing_workspace)

    assert {:error, changeset} =
             Runs.create_run(%{
               "title" => "Missing workspace",
               "workspace" => missing_workspace
             })

    assert %{workspace: ["must be an existing directory"]} = errors_on(changeset)
    assert Runs.list_runs() == []
  end

  test "create_run rejects statuses outside the canonical run vocabulary" do
    assert {:error, changeset} =
             Runs.create_run(%{
               "title" => "Impossible status",
               "workspace" => File.cwd!(),
               "status" => "maybe_running"
             })

    assert %{status: ["is invalid"]} = errors_on(changeset)
    assert Runs.list_runs() == []
  end

  test "update_status! rejects statuses outside the canonical run vocabulary" do
    run = insert_run!("Status boundary", "idle")

    error =
      assert_raise Ecto.InvalidChangesetError, fn ->
        Runs.update_status!(run.id, %{status: "paused-ish"})
      end

    assert %{status: ["is invalid"]} = errors_on(error.changeset)

    assert Runs.get_run!(run.id).status == "idle"
  end

  test "archive_run hides terminal runs but rejects active runs" do
    failed = insert_run!("Failed run", "failed")
    running = insert_run!("Running run", "running")

    assert {:ok, archived} = Runs.archive_run(failed.id)
    assert archived.archived_at
    assert Runs.get_run!(failed.id).archived_at
    refute failed.id in Enum.map(Runs.list_runs(), & &1.id)

    assert [%{type: "run_created"}, %{type: "run_archived"}] = Events.list_for_run(failed.id)
    assert {:error, :not_archivable} = Runs.archive_run(running.id)
    refute Runs.get_run!(running.id).archived_at
  end

  test "archived runs are read-only and cannot be restarted" do
    run = insert_run!("Archived boundary", "failed")
    assert {:ok, archived} = Runs.archive_run(run.id)

    assert {:error, :archived_run} = Runs.start_run(archived.id)
    assert {:error, :archived_run} = Runs.ensure_started(archived.id)
    assert {:error, :archived_run} = Runs.reconnect_run(archived.id)
    assert {:error, :archived_run} = Runs.retry_last_prompt(archived.id)

    assert [
             %{type: "run_created"},
             %{type: "run_archived"}
           ] = Events.list_for_run(archived.id)
  end

  test "prune_archived_before deletes only archived runs older than the cutoff" do
    old_archived =
      "Old archived run"
      |> insert_run!("failed")
      |> set_archived_at!(~U[2026-01-01 00:00:00Z])

    recent_archived =
      "Recent archived run"
      |> insert_run!("failed")
      |> set_archived_at!(~U[2026-06-01 00:00:00Z])

    active = insert_run!("Active failed run", "failed")

    assert 1 == Runs.prune_archived_before(~U[2026-02-01 00:00:00Z])

    refute Repo.get(Run, old_archived.id)
    assert [] == Events.list_for_run(old_archived.id)
    assert Runs.get_run!(recent_archived.id).archived_at
    refute Runs.get_run!(active.id).archived_at
  end

  test "normalizes optional file capability path scopes" do
    changeset =
      Run.changeset(%Run{}, %{
        title: "Scoped run",
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: "idle",
        capability_policy: %{
          "file_read" => "allow",
          "file_read_paths" => [" README.md ", "", "docs", "docs"],
          file_write: "ask",
          file_write_paths: "tmp"
        }
      })

    assert changeset.valid?

    assert Ecto.Changeset.get_change(changeset, :capability_policy) == %{
             "file_read" => "allow",
             "file_read_paths" => ["README.md", "docs"],
             "file_write" => "ask",
             "file_write_paths" => ["tmp"],
             "terminal_create" => "allow"
           }
  end

  defp insert_run!(title, status) do
    run =
      %Run{}
      |> Run.changeset(%{
        title: title,
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: status
      })
      |> Repo.insert!()

    Events.append!(run.id, "run_created", %{
      "title" => run.title,
      "workspace" => run.workspace,
      "agent" => run.agent
    })

    run
  end

  defp set_archived_at!(%Run{} = run, archived_at) do
    run
    |> Ecto.Changeset.change(archived_at: archived_at)
    |> Repo.update!()
  end
end
