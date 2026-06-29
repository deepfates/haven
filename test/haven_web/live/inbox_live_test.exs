defmodule HavenWeb.InboxLiveTest do
  use HavenWeb.ConnCase

  alias Haven.Events
  alias Haven.Agents
  alias Haven.Repo
  alias Haven.Runs
  alias Haven.Runs.Run
  alias Haven.Workspaces

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
  test "saves a workspace from the inbox and uses it for a run", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace-form")
    assert has_element?(view, "#workspace-empty")

    view
    |> form("#workspace-form", %{
      "workspace_config" => %{
        "name" => "Scratch repo",
        "path" => tmp_dir
      }
    })
    |> render_submit()

    [workspace] = Workspaces.list_workspaces()
    assert workspace.name == "Scratch repo"
    assert workspace.path == Path.expand(tmp_dir)
    assert has_element?(view, "#workspace-#{workspace.id}")
    assert has_element?(view, ~s|#workspace_id option[value="#{workspace.id}"]|)

    view
    |> form("#new-run-form", %{
      "title" => "Saved workspace run",
      "workspace_id" => workspace.id,
      "workspace" => "/ignored/manual/path"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Saved workspace run"
    assert run.workspace == Path.expand(tmp_dir)
    assert_redirect(view, ~p"/runs/#{run.id}")
  end

  test "shows validation errors for invalid saved workspaces", %{conn: conn} do
    missing_workspace = Path.join(System.tmp_dir!(), "haven-missing-saved-workspace")
    File.rm_rf!(missing_workspace)

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#workspace-form", %{
        "workspace_config" => %{
          "name" => "Missing",
          "path" => missing_workspace
        }
      })
      |> render_submit()

    assert html =~ "must be an existing directory"
    assert has_element?(view, "#workspace-error")
    assert Workspaces.list_workspaces() == []
  end

  @tag :tmp_dir
  test "deletes a saved workspace from the inbox picker", %{conn: conn, tmp_dir: tmp_dir} do
    assert {:ok, workspace} =
             Workspaces.create_workspace(%{
               "name" => "Delete me",
               "path" => tmp_dir
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace-#{workspace.id}")
    assert has_element?(view, ~s|#workspace_id option[value="#{workspace.id}"]|)

    view
    |> element("#delete-workspace-#{workspace.id}")
    |> render_click()

    refute has_element?(view, "#workspace-#{workspace.id}")
    refute has_element?(view, ~s|#workspace_id option[value="#{workspace.id}"]|)
    assert Workspaces.list_workspaces() == []
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

  @tag :tmp_dir
  test "creates a run with a persisted agent config", %{conn: conn, tmp_dir: tmp_dir} do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "persisted-stub",
               executable: "mix",
               args: ["run", "--no-compile", "--no-start", "priv/agent_stub.exs", "{workspace}"]
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s|#agent option[value="persisted-stub"]|)

    view
    |> form("#new-run-form", %{
      "title" => "Persisted agent run",
      "workspace" => tmp_dir,
      "agent" => "persisted-stub"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Persisted agent run"
    assert run.workspace == Path.expand(tmp_dir)
    assert run.agent == "persisted-stub"
    assert_redirect(view, ~p"/runs/#{run.id}")
  end

  @tag :tmp_dir
  test "saves an agent config from the inbox and uses it for a run", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, ~s|#agent option[value="inbox-stub"]|)
    assert has_element?(view, "#agent-config-form")

    view
    |> form("#agent-config-form", %{
      "agent_config" => %{
        "key" => "inbox-stub",
        "executable" => "mix",
        "args_text" => "run\n--no-compile\n--no-start\npriv/agent_stub.exs\n{workspace}",
        "cwd" => "",
        "env_text" => "WORKSPACE={workspace}"
      }
    })
    |> render_submit()

    assert has_element?(view, "#agent-config-inbox-stub")
    assert has_element?(view, ~s|#agent option[value="inbox-stub"]|)

    view
    |> form("#new-run-form", %{
      "title" => "Inbox configured agent run",
      "workspace" => tmp_dir,
      "agent" => "inbox-stub"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Inbox configured agent run"
    assert run.workspace == Path.expand(tmp_dir)
    assert run.agent == "inbox-stub"
    assert_redirect(view, ~p"/runs/#{run.id}")
  end

  test "shows validation errors when saving an invalid inbox agent config", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#agent-config-form", %{
        "agent_config" => %{
          "key" => "bad key",
          "executable" => "",
          "args_text" => "",
          "cwd" => "",
          "env_text" => "BROKEN"
        }
      })
      |> render_submit()

    assert html =~ "Environment lines must use KEY=value"
    assert has_element?(view, "#agent-config-error")
    assert Agents.list_agent_configs() == []
  end

  test "edits and deletes an agent config from the inbox", %{conn: conn} do
    assert {:ok, agent_config} =
             Agents.create_agent_config(%{
               key: "editable-stub",
               executable: "mix",
               args: ["before"]
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#agent-config-editable-stub")
    assert has_element?(view, ~s|#agent option[value="editable-stub"]|)

    view
    |> element("#edit-agent-config-editable-stub")
    |> render_click()

    assert has_element?(view, "#cancel-agent-config-edit-button")

    view
    |> form("#agent-config-form", %{
      "agent_config" => %{
        "id" => agent_config.id,
        "key" => "edited-stub",
        "executable" => "mix",
        "args_text" => "after\n{workspace}",
        "cwd" => "{workspace}",
        "env_text" => "WORKSPACE={workspace}"
      }
    })
    |> render_submit()

    refute has_element?(view, "#agent-config-editable-stub")
    refute has_element?(view, ~s|#agent option[value="editable-stub"]|)
    assert has_element?(view, "#agent-config-edited-stub")
    assert has_element?(view, ~s|#agent option[value="edited-stub"]|)

    assert {:ok, command} = Agents.command("edited-stub", "/repo")
    assert command.args == ["after", "/repo"]
    assert command.cwd == "/repo"
    assert command.env == [{"WORKSPACE", "/repo"}]

    view
    |> element("#delete-agent-config-edited-stub")
    |> render_click()

    refute has_element?(view, "#agent-config-edited-stub")
    refute has_element?(view, ~s|#agent option[value="edited-stub"]|)
    assert Agents.list_agent_configs() == []
  end

  test "groups runs into operational attention lanes", %{conn: conn} do
    insert_run!("Needs approval", "waiting")
    insert_run!("Still working", "running")
    insert_run!("Quiet", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "section", "Needs You")
    assert has_element?(view, "section", "Running")
    assert has_element?(view, "section", "History")
    assert has_element?(view, "article", "Needs approval")
    assert has_element?(view, "article", "Still working")
    assert has_element?(view, "article", "Quiet")
  end

  test "moves live runs between attention lanes as their status changes", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Lane movement run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "section", "History")
    assert has_element?(view, "article", "Lane movement run")

    assert :ok = Runs.send_prompt(run.id, "permission")

    assert_receive {:event_appended, %{type: "permission_requested"}}, 1_000
    assert_receive {:run_updated, %{id: id, status: "waiting"}}, 1_000
    assert id == run.id

    assert has_element?(view, "section", "Needs You")
    assert has_element?(view, "article", "Lane movement run")

    assert :ok = Runs.resolve_permission(run.id, 1, "allow")
    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    assert_receive {:run_updated, %{id: id, status: "idle"}}, 1_000
    assert id == run.id

    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run.id)
    _ = :sys.get_state(pid)

    refute has_element?(view, "section", "Needs You")
    assert has_element?(view, "section", "History")
    assert has_element?(view, "article", "Lane movement run")
  end

  test "archives terminal runs from history without deleting their events", %{conn: conn} do
    run = insert_run!("Old failure", "failed")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "article", "Old failure")
    assert has_element?(view, "#archive-run-#{run.id}")

    view
    |> element("#archive-run-#{run.id}")
    |> render_click()

    refute has_element?(view, "article", "Old failure")
    assert Runs.list_runs() == []

    archived = Runs.get_run!(run.id)
    assert archived.archived_at

    assert [%{type: "run_created"}, %{type: "run_archived", payload: payload}] =
             Events.list_for_run(run.id)

    assert payload["actor"] == "local_user"
    assert payload["previous_status"] == "failed"
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

  defp sync_run_server!(run_id) do
    {:ok, pid} = Runs.ensure_started(run_id)
    _ = :sys.get_state(pid)
    pid
  end
end
