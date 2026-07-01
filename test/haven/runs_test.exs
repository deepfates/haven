defmodule Haven.RunsTest do
  use Haven.DataCase

  alias Haven.Agents
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

  test "create_run rejects unknown agents before creating durable history" do
    assert {:error, changeset} =
             Runs.create_run(%{
               "title" => "Unknown agent",
               "workspace" => File.cwd!(),
               "agent" => "missing-agent"
             })

    assert %{agent: ["is not configured: missing-agent"]} = errors_on(changeset)
    assert Runs.list_runs() == []
  end

  test "create_run rejects agents with missing working directories before creating durable history" do
    missing_cwd = Path.join(System.tmp_dir!(), "haven-missing-run-agent-cwd")
    File.rm_rf!(missing_cwd)

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "missing-cwd-agent",
               executable: "sh",
               cwd: missing_cwd
             })

    assert {:error, changeset} =
             Runs.create_run(%{
               "title" => "Missing cwd agent",
               "workspace" => File.cwd!(),
               "agent" => "missing-cwd-agent"
             })

    assert %{agent: ["working directory is missing: " <> _path]} = errors_on(changeset)
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

  test "archive_run stops a lingering process for terminal history" do
    run = insert_run!("Lingering failed run", "idle")
    assert {:ok, pid} = Runs.start_run(run.id)
    _ = :sys.get_state(pid)

    Runs.update_status!(run.id, %{status: "failed"})
    ref = Process.monitor(pid)

    assert {:ok, archived} = Runs.archive_run(run.id)
    assert archived.archived_at
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    refute Runs.started?(run.id)
  end

  test "archived runs are read-only and cannot be restarted" do
    run = insert_run!("Archived boundary", "failed")
    assert {:ok, archived} = Runs.archive_run(run.id)

    assert {:error, :archived_run} = Runs.start_run(archived.id)
    assert {:error, :archived_run} = Runs.ensure_started(archived.id)
    assert {:error, :archived_run} = Runs.reconnect_run(archived.id)
    assert {:error, :archived_run} = Runs.retry_last_prompt(archived.id)
    assert {:error, :archived_run} = Runs.continue_failed_run(archived.id, "next step")

    assert [
             %{type: "run_created"},
             %{type: "run_archived"}
           ] = Events.list_for_run(archived.id)
  end

  test "continue_failed_run only accepts nonblank prompts for failed runs" do
    idle = insert_run!("Idle continue boundary", "idle")
    failed = insert_run!("Failed continue boundary", "failed")

    assert {:error, :not_failed} = Runs.continue_failed_run(idle.id, "next step")
    assert {:error, :blank_prompt} = Runs.continue_failed_run(failed.id, "   ")
  end

  test "direct start_run refuses terminal history without appending lifecycle events" do
    failed = insert_run!("Failed direct start boundary", "failed")
    closed = insert_run!("Closed direct start boundary", "closed")

    assert {:error, :terminal_run} = Runs.start_run(failed.id)
    assert {:error, :terminal_run} = Runs.start_run(closed.id)

    assert [%{type: "run_created"}] = Events.list_for_run(failed.id)
    assert [%{type: "run_created"}] = Events.list_for_run(closed.id)
  end

  @tag :tmp_dir
  test "direct start_run refuses missing historical workspaces without appending lifecycle events",
       %{
         tmp_dir: tmp_dir
       } do
    workspace = Path.join(tmp_dir, "vanished")
    File.mkdir_p!(workspace)
    run = insert_run!("Missing workspace start boundary", "idle", workspace)
    File.rm_rf!(workspace)

    assert {:error, {:missing_workspace, ^workspace}} = Runs.start_run(run.id)
    assert [%{type: "run_created"}] = Events.list_for_run(run.id)
    refute Runs.started?(run.id)
  end

  @tag :tmp_dir
  test "reconnect refuses missing historical workspaces without rewriting run history", %{
    tmp_dir: tmp_dir
  } do
    workspace = Path.join(tmp_dir, "vanished")
    File.mkdir_p!(workspace)
    run = insert_run!("Missing workspace reconnect boundary", "failed", workspace)
    Events.append!(run.id, "user_message", %{"text" => "try again"})
    File.rm_rf!(workspace)

    assert {:error, {:missing_workspace, ^workspace}} = Runs.reconnect_run(run.id)
    assert Runs.get_run!(run.id).status == "failed"

    events = Events.list_for_run(run.id)
    refute Enum.any?(events, &(&1.type == "run_reconnect_requested"))
    refute Enum.any?(events, &(&1.type == "turn_failed"))
    refute Runs.started?(run.id)
  end

  @tag :tmp_dir
  test "send_prompt refuses missing historical workspaces before starting a process", %{
    tmp_dir: tmp_dir
  } do
    workspace = Path.join(tmp_dir, "vanished")
    File.mkdir_p!(workspace)
    run = insert_run!("Missing workspace prompt boundary", "idle", workspace)
    File.rm_rf!(workspace)

    assert {:error, {:missing_workspace, ^workspace}} = Runs.send_prompt(run.id, "hello")
    assert [%{type: "run_created"}] = Events.list_for_run(run.id)
    refute Runs.started?(run.id)
  end

  test "ensure_started trusts durable terminal state before stale registry liveness" do
    closed = insert_run!("Closed stale registry boundary", "closed")
    assert {:ok, _} = Registry.register(Haven.Runs.Registry, closed.id, :stale)

    assert Registry.lookup(Haven.Runs.Registry, closed.id) == [{self(), :stale}]
    assert {:error, :terminal_run} = Runs.ensure_started(closed.id)

    assert [%{type: "run_created"}] = Events.list_for_run(closed.id)
  end

  test "started? reports false for terminal and archived history despite stale registry liveness" do
    closed = insert_run!("Closed started boundary", "closed")
    archived_source = insert_run!("Archived started boundary", "failed")
    assert {:ok, archived} = Runs.archive_run(archived_source.id)

    assert {:ok, _} = Registry.register(Haven.Runs.Registry, closed.id, :closed_stale)
    assert {:ok, _} = Registry.register(Haven.Runs.Registry, archived.id, :archived_stale)

    refute Runs.started?(closed.id)
    refute Runs.started?(archived.id)
    refute Runs.started?(closed)
    refute Runs.started?(archived)
  end

  test "started? accepts an already loaded active run without refetching it" do
    run = insert_run!("Loaded started boundary", "idle")
    assert {:ok, _} = Registry.register(Haven.Runs.Registry, run.id, :live)

    parent = self()
    telemetry_id = "runs-started-loaded-run-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:haven, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:repo_query, metadata.query})
        end,
        nil
      )

    try do
      assert Runs.started?(run)
      refute_receive {:repo_query, _query}, 50
    after
      :telemetry.detach(telemetry_id)
    end
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

  defp insert_run!(title, status, workspace \\ File.cwd!()) do
    run =
      %Run{}
      |> Run.changeset(%{
        title: title,
        workspace: workspace,
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
