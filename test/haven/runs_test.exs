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
end
