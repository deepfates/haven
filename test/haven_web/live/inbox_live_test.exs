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
    assert has_element?(view, "#file_read_paths")
    assert has_element?(view, "#file_write_paths")
    assert has_element?(view, "#terminal_create_policy option[value='ask']")

    view
    |> form("#new-run-form", %{
      "title" => "Review agent changes",
      "file_read_policy" => "allow",
      "file_read_paths" => " README.md, docs ",
      "file_write_policy" => "deny",
      "file_write_paths" => "notes, tmp/output.md",
      "terminal_create_policy" => "ask"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Review agent changes"

    assert run.capability_policy == %{
             "file_read" => "allow",
             "file_read_paths" => ["README.md", "docs"],
             "file_write" => "deny",
             "file_write_paths" => ["notes", "tmp/output.md"],
             "terminal_create" => "ask"
           }

    assert_redirect(view, ~p"/runs/#{run.id}")
  end

  test "renders runs before setup panels in the mobile-first inbox hierarchy", %{conn: conn} do
    insert_run!("Quiet run", "idle")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Inbox"
    assert html =~ "History"

    history_index = :binary.match(html, "Quiet run") |> elem(0)
    workspace_index = :binary.match(html, "workspaces-panel") |> elem(0)
    agent_setup_index = :binary.match(html, "agent-configs-panel") |> elem(0)

    assert history_index < workspace_index
    assert history_index < agent_setup_index
  end

  test "keeps setup surfaces behind secondary inbox disclosures", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspaces-panel summary", "Manage workspaces")
    assert has_element?(view, "#agent-configs-panel summary", "Manage agents")
    assert has_element?(view, "#workspace-form")
    assert has_element?(view, "#agent-config-form")
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
  test "edits a saved workspace from the inbox picker", %{conn: conn, tmp_dir: tmp_dir} do
    next_dir = Path.join(tmp_dir, "next")
    File.mkdir_p!(next_dir)

    assert {:ok, workspace} =
             Workspaces.create_workspace(%{
               "name" => "Before repo",
               "path" => tmp_dir
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace-#{workspace.id}", "Before repo")
    assert has_element?(view, ~s|#workspace_id option[value="#{workspace.id}"]|)

    view
    |> element("#edit-workspace-#{workspace.id}")
    |> render_click()

    assert has_element?(view, "#cancel-workspace-edit-button")

    view
    |> form("#workspace-form", %{
      "workspace_config" => %{
        "id" => workspace.id,
        "name" => "After repo",
        "path" => next_dir
      }
    })
    |> render_submit()

    assert has_element?(view, "#workspace-#{workspace.id}", "After repo")
    assert has_element?(view, ~s|#workspace_id option[value="#{workspace.id}"]|)
    refute has_element?(view, "#cancel-workspace-edit-button")

    [updated] = Workspaces.list_workspaces()
    assert updated.id == workspace.id
    assert updated.name == "After repo"
    assert updated.path == Path.expand(next_dir)

    view
    |> form("#new-run-form", %{
      "title" => "Edited workspace run",
      "workspace_id" => workspace.id,
      "workspace" => "/ignored/manual/path"
    })
    |> render_submit()

    [run] = Runs.list_runs()
    stop_run_server_on_exit(run.id)

    assert run.title == "Edited workspace run"
    assert run.workspace == Path.expand(next_dir)
    assert_redirect(view, ~p"/runs/#{run.id}")
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
    assert has_element?(view, "#agent-config-inbox-stub-evidence", "Local harness")
    refute has_element?(view, "#agent-config-inbox-stub-probe-command")

    assert has_element?(
             view,
             "#agent-config-inbox-stub-evidence-reason",
             "agent command uses a local test harness"
           )

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

  test "shows probe evidence readiness for saved agent configs", %{conn: conn} do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "candidate-agent",
               executable: "sh",
               args: ["-c", "cat"],
               env: %{"SECRET" => "hidden-value"}
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#agent-config-candidate-agent-evidence", "Static candidate")
    assert has_element?(view, "#agent-config-candidate-agent-probe-basic", "Basic boot proof")

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-command",
             "--require-real-agent"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-command",
             "docs/probes/candidate-agent-basic.json"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-denied",
             "Capability guard proof"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-denied-command",
             "--expect-event-field"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-denied-command",
             "terminal_create_requested:payload.command=mix"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-denied-command",
             "capability_policy_applied:payload.decision=deny"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-denied-command",
             "docs/probes/candidate-agent-terminal-denied.json"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-file-read",
             "File read proof"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-file-read-command",
             "--file-read-policy allow"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-file-read-command",
             "file_read_succeeded:payload.path=README.md"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-file-write-approval",
             "File write approval proof"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-file-write-approval-command",
             "--resolve-permissions allow"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-file-write-approval-command",
             "file_write_requested:payload.path=notes/haven-probe.txt"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-approval",
             "Terminal approval proof"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-approval-command",
             "--terminal-create-policy ask"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-probe-terminal-approval-command",
             "terminal_output_succeeded:payload.exit_status=0"
           )

    assert has_element?(
             view,
             "#agent-config-candidate-agent-evidence-reason",
             "not ACP evidence until preflight or a generated probe passes"
           )

    refute render(view) =~ "hidden-value"
  end

  test "shows public registry discovery command in agent setup", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#agent-registry-hint", "Find real ACP agents")

    assert has_element?(
             view,
             "#agent-registry-command",
             "mix haven.agent_probe --list-agents --registry"
           )

    assert has_element?(
             view,
             "#agent-registry-hint",
             "download and run third-party code"
           )
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
    waiting = insert_run!("Needs approval", "waiting")
    insert_run!("Still working", "running")
    failed = insert_run!("Needs restart", "failed")
    insert_run!("Quiet", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#inbox-needs-you-section")
    assert has_element?(view, "#inbox-running-section")
    assert has_element?(view, "#inbox-history-section")
    assert has_element?(view, "article", "Needs approval")
    assert has_element?(view, "#run-#{waiting.id}-attention", "Needs decision")
    assert has_element?(view, "a", "Decide")
    assert has_element?(view, "article", "Still working")
    assert has_element?(view, "article", "Needs restart")
    assert has_element?(view, "#run-#{failed.id}-attention", "Needs recovery")
    assert has_element?(view, "a", "Recover")
    assert has_element?(view, "article", "Quiet")
  end

  test "filters inbox runs by operational lane", %{conn: conn} do
    insert_run!("Needs approval", "waiting")
    insert_run!("Still working", "running")
    insert_run!("Quiet", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#inbox-filter-all", "3")
    assert has_element?(view, "#inbox-filter-needs_you", "1")
    assert has_element?(view, "#inbox-filter-running", "1")
    assert has_element?(view, "#inbox-filter-history", "1")

    view
    |> element("#inbox-filter-running")
    |> render_click()

    assert has_element?(view, "#inbox-running-section")
    assert has_element?(view, "article", "Still working")
    refute has_element?(view, "article", "Needs approval")
    refute has_element?(view, "article", "Quiet")

    view
    |> element("#inbox-filter-history")
    |> render_click()

    assert has_element?(view, "#inbox-history-section")
    assert has_element?(view, "article", "Quiet")
    refute has_element?(view, "article", "Still working")
  end

  @tag :tmp_dir
  test "searches inbox runs by row facts and latest activity", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    matching_workspace = Path.join(tmp_dir, "project-alpha")
    other_workspace = Path.join(tmp_dir, "project-beta")
    File.mkdir_p!(matching_workspace)
    File.mkdir_p!(other_workspace)

    matched = insert_run!("Docs cleanup", "idle", %{workspace: matching_workspace})
    insert_run!("Payment bug", "waiting", %{workspace: other_workspace, agent: "other-acp"})

    Events.append!(matched.id, "file_write_succeeded", %{"path" => "notes/result.md"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#inbox-search-form")
    assert has_element?(view, "#run_search")

    view
    |> form("#inbox-search-form", %{"run_search" => "project-alpha"})
    |> render_change()

    assert has_element?(view, "article", "Docs cleanup")
    refute has_element?(view, "article", "Payment bug")
    assert has_element?(view, "#inbox-filter-all", "1")

    view
    |> form("#inbox-search-form", %{"run_search" => "other-acp"})
    |> render_change()

    assert has_element?(view, "article", "Payment bug")
    refute has_element?(view, "article", "Docs cleanup")
    assert has_element?(view, "#inbox-filter-needs_you", "1")

    view
    |> form("#inbox-search-form", %{"run_search" => "needs decision"})
    |> render_change()

    assert has_element?(view, "article", "Payment bug")
    refute has_element?(view, "article", "Docs cleanup")

    view
    |> form("#inbox-search-form", %{"run_search" => "notes/result.md"})
    |> render_change()

    assert has_element?(view, "article", "Docs cleanup")
    refute has_element?(view, "article", "Payment bug")

    view
    |> form("#inbox-search-form", %{"run_search" => "not-here"})
    |> render_change()

    assert has_element?(view, "#inbox-filter-empty", "No runs match your search.")
    refute has_element?(view, "article", "Docs cleanup")

    view
    |> element("#clear-inbox-search")
    |> render_click()

    assert has_element?(view, "article", "Docs cleanup")
    assert has_element?(view, "article", "Payment bug")
  end

  test "shows an empty state for a filtered lane with no runs", %{conn: conn} do
    insert_run!("Quiet", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#inbox-filter-needs_you")
    |> render_click()

    assert has_element?(view, "#inbox-filter-empty", "No runs in this view.")
    refute has_element?(view, "article", "Quiet")
  end

  test "renders latest run activity in inbox rows", %{conn: conn} do
    run = insert_run!("Activity row", "idle")

    Events.append!(run.id, "agent_message_chunk", %{
      "text" => "Reviewed the workspace\nand found one issue."
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#run-#{run.id}-latest-activity",
             "Agent: Reviewed the workspace and found one issue."
           )
  end

  test "updates latest activity when a run event arrives without a status change", %{conn: conn} do
    run = insert_run!("Live activity row", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#run-#{run.id}-latest-activity", "Run created")

    Events.append!(run.id, "file_write_succeeded", %{"path" => "notes/result.md"})

    assert has_element?(view, "#run-#{run.id}-latest-activity", "Wrote file: notes/result.md")
  end

  test "moves live runs between attention lanes as their status changes", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Lane movement run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#inbox-history-section")
    assert has_element?(view, "article", "Lane movement run")

    assert :ok = Runs.send_prompt(run.id, "permission")

    assert_receive {:event_appended, %{type: "permission_requested"}}, 1_000
    assert_receive {:run_updated, %{id: id, status: "waiting"}}, 1_000
    assert id == run.id

    assert has_element?(view, "#inbox-needs-you-section")
    assert has_element?(view, "article", "Lane movement run")

    assert :ok = Runs.resolve_permission(run.id, 1, "allow")
    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    assert_receive {:run_updated, %{id: id, status: "idle"}}, 1_000
    assert id == run.id

    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run.id)
    _ = :sys.get_state(pid)

    refute has_element?(view, "#inbox-needs-you-section")
    assert has_element?(view, "#inbox-history-section")
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
    assert [archived_run] = Runs.list_archived_runs()
    assert archived_run.id == run.id

    assert [%{type: "run_created"}, %{type: "run_archived", payload: payload}] =
             Events.list_for_run(run.id)

    assert payload["actor"] == "local_user"
    assert payload["previous_status"] == "failed"

    assert has_element?(view, "#inbox-filter-archived", "1")

    view
    |> element("#inbox-filter-archived")
    |> render_click()

    assert has_element?(view, "#inbox-archived-section")
    assert has_element?(view, "article", "Old failure")
    assert has_element?(view, "#run-#{run.id}-archived-at", "Archived")
  end

  defp insert_run!(title, status, attrs \\ %{}) do
    run =
      %Run{}
      |> Run.changeset(
        Map.merge(
          %{
            title: title,
            workspace: File.cwd!(),
            agent: "stub-acp",
            status: status
          },
          attrs
        )
      )
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
