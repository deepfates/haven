defmodule HavenWeb.InboxLiveTest do
  use HavenWeb.ConnCase

  alias Haven.Events
  alias Haven.Repo
  alias Haven.Runs
  alias Haven.Runs.Run

  setup do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)
  end

  test "creates a run from the inbox and navigates to the run detail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#haven-inbox")
    assert has_element?(view, "#new-run-form")
    assert has_element?(view, "#agent")
    assert has_element?(view, "#workspace")

    view
    |> form("#new-run-form", %{
      "title" => "Review agent changes"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Review agent changes"
    assert_redirect(view, ~p"/runs/#{run.id}")
  end

  test "rejects a run with a missing workspace", %{conn: conn} do
    missing_workspace = Path.join(System.tmp_dir!(), "haven-missing-workspace")
    File.rm_rf!(missing_workspace)

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#new-run-form", %{
        "title" => "Invalid workspace run",
        "workspace" => missing_workspace
      })
      |> render_submit()

    assert html =~ "must be an existing directory"
    assert Runs.list_runs() == []
    refute_redirected(view)
  end

  @tag :tmp_dir
  test "creates a run with the selected workspace and configured agent", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    Application.put_env(:haven, :agents, %{
      "configured-stub" => %{
        executable: System.find_executable("mix"),
        args: ["run", "--no-compile", "--no-start", "priv/agent_stub.exs", "{workspace}"]
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s|#agent option[value="configured-stub"]|)

    view
    |> form("#new-run-form", %{
      "title" => "Custom context run",
      "workspace" => tmp_dir,
      "agent" => "configured-stub"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Custom context run"
    assert run.workspace == Path.expand(tmp_dir)
    assert run.agent == "configured-stub"
    assert_redirect(view, ~p"/runs/#{run.id}")
  end

  test "groups runs into operational attention lanes", %{conn: conn} do
    insert_run!("Needs approval", "waiting")
    insert_run!("Still working", "running")
    insert_run!("Quiet", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "section", "Needs You")
    assert has_element?(view, "section", "Running")
    assert has_element?(view, "section", "History")
    assert has_element?(view, "a", "Needs approval")
    assert has_element?(view, "a", "Still working")
    assert has_element?(view, "a", "Quiet")
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

  defp stop_run_server_on_exit(run_id) do
    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Haven.Runs.Registry, run_id) do
        DynamicSupervisor.terminate_child(Haven.Runs.Supervisor, pid)
      end
    end)
  end
end
