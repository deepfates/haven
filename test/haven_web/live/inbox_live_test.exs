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
    assert has_element?(view, "#new-run-agent-evidence")
    assert has_element?(view, "#new-run-agent-key", "stub-acp")
    assert has_element?(view, "#new-run-agent-trust", "Local harness")

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

  test "updates selected agent evidence before starting a run", %{conn: conn} do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "codex-acp",
               executable: "sh",
               args: ["-c", "cat"]
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#new-run-agent-key", "stub-acp")
    assert has_element?(view, "#new-run-agent-trust", "Local harness")

    view
    |> form("#new-run-form", %{
      "title" => "Evidence-aware run",
      "agent" => "codex-acp"
    })
    |> render_change()

    assert has_element?(view, "#new-run-agent-key", "codex-acp")
    assert has_element?(view, "#new-run-agent-launch", "Launch ready")
    assert has_element?(view, "#new-run-agent-trust", "3 accepted probes")

    assert has_element?(
             view,
             "#new-run-agent-evidence-reason",
             "validated committed reports"
           )
  end

  test "renders runs before setup panels in the mobile-first inbox hierarchy", %{conn: conn} do
    insert_run!("Quiet run", "idle")

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Inbox"
    assert html =~ "History"
    assert has_element?(view, "#new-run-panel:not([open])")
    assert has_element?(view, "#new-run-panel summary", "Start a run")
    assert has_element?(view, "#new-run-form")

    history_index = :binary.match(html, "Quiet run") |> elem(0)
    workspace_index = :binary.match(html, "workspaces-panel") |> elem(0)
    agent_setup_index = :binary.match(html, "agent-configs-panel") |> elem(0)

    assert history_index < workspace_index
    assert history_index < agent_setup_index
  end

  test "renders a first-run empty state without opening setup panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#inbox-attention-summary")
    assert has_element?(view, "#inbox-attention-label", "No runs yet")
    assert has_element?(view, "#inbox-attention-detail", "Ready when you are")
    assert has_element?(view, "#new-run-panel:not([open])")
    assert has_element?(view, "#inbox-first-run-empty", "No runs yet.")
    assert has_element?(view, "#inbox-first-run-empty", "Open Start a run")
    assert has_element?(view, "#workspaces-panel:not([open])")
    assert has_element?(view, "#agent-configs-panel:not([open])")
  end

  test "renders an attention summary that jumps to the most urgent lane", %{conn: conn} do
    waiting = insert_run!("Needs approval", "waiting")
    running = insert_run!("Working run", "running")
    history = insert_run!("Done run", "idle")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#inbox-attention-label", "1 decision")
    assert has_element?(view, "#inbox-attention-detail", "1 running")
    assert has_element?(view, "#inbox-attention-detail", "1 history")

    view
    |> element("#inbox-attention-primary")
    |> render_click()

    assert has_element?(view, "#inbox-needs-you-section")
    assert has_element?(view, "#run-#{waiting.id}")
    refute has_element?(view, "#run-#{running.id}")
    refute has_element?(view, "#run-#{history.id}")
  end

  test "keeps setup surfaces behind secondary inbox disclosures", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspaces-panel summary", "Manage workspaces")
    assert has_element?(view, "#agent-configs-panel summary", "Manage agents")
    assert has_element?(view, "#workspace-form")
    assert has_element?(view, "#agent-config-form")
  end

  test "renders run rows as next-action triage items", %{conn: conn} do
    waiting = insert_run!("Review permissions", "waiting")
    failed = insert_run!("Fix crash", "failed")
    archived_failure = insert_run!("Old crash", "failed")
    assert {:ok, _archived} = Runs.archive_run(archived_failure.id)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#run-#{waiting.id}-next-step", "Reconnect before deciding")
    assert has_element?(view, "#run-#{waiting.id}-agent", "stub-acp")
    assert has_element?(view, "#run-#{waiting.id}-agent-launch", "Launch ready")
    assert has_element?(view, "#run-#{waiting.id}-agent-trust", "Local harness")

    assert has_element?(
             view,
             "#run-#{failed.id}-next-step",
             "Continue, retry, or inspect failure"
           )

    view
    |> element("#inbox-filter-archived")
    |> render_click()

    assert has_element?(view, "#run-#{archived_failure.id}-next-step", "Review history")
    assert has_element?(view, "#run-#{archived_failure.id} a", "Review")
    refute has_element?(view, "#run-#{archived_failure.id} a", "Recover")
  end

  test "renders evidence-backed agent trust in run rows", %{conn: conn} do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "codex-acp",
               executable: "sh",
               args: ["-c", "cat"]
             })

    run = insert_run!("Evidence row", "idle", %{agent: "codex-acp"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#run-#{run.id}-agent", "codex-acp")
    assert has_element?(view, "#run-#{run.id}-agent-launch", "Launch ready")
    assert has_element?(view, "#run-#{run.id}-agent-trust", "3 accepted probes")
  end

  @tag :tmp_dir
  test "renders run rows with recognizable workspace identity", %{conn: conn, tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "project-alpha")
    parent = Path.dirname(workspace)
    File.mkdir_p!(workspace)
    run = insert_run!("Folder-aware run", "idle", %{workspace: workspace})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s|#run-#{run.id}-workspace[title="#{workspace}"]|)
    assert has_element?(view, "#run-#{run.id}-workspace", "project-alpha")
    assert has_element?(view, "#run-#{run.id}-workspace-path", parent)
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
    assert has_element?(view, "#new-run-panel[open]")
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
  test "summarizes saved workspace readiness and run usage", %{conn: conn, tmp_dir: tmp_dir} do
    ready_dir = Path.join(tmp_dir, "ready")
    missing_dir = Path.join(tmp_dir, "missing")
    File.mkdir_p!(ready_dir)
    File.mkdir_p!(missing_dir)

    assert {:ok, ready_workspace} =
             Workspaces.create_workspace(%{
               "name" => "Ready repo",
               "path" => ready_dir
             })

    assert {:ok, missing_workspace} =
             Workspaces.create_workspace(%{
               "name" => "Missing repo",
               "path" => missing_dir
             })

    insert_run!("Active workspace run", "idle", %{workspace: Path.expand(ready_dir)})

    archived_run =
      insert_run!("Archived workspace run", "failed", %{workspace: Path.expand(ready_dir)})

    assert {:ok, _archived} = Runs.archive_run(archived_run.id)
    File.rm_rf!(missing_dir)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace-#{ready_workspace.id}-path-state", "Ready")
    assert has_element?(view, "#workspace-#{ready_workspace.id}-run-usage", "1 active run")
    assert has_element?(view, "#workspace-#{ready_workspace.id}-run-usage", "1 archived run")

    assert has_element?(view, "#workspace-#{missing_workspace.id}-path-state", "Missing")
    assert has_element?(view, "#workspace-#{missing_workspace.id}-run-usage", "0 active runs")
    assert has_element?(view, "#workspace-#{missing_workspace.id}-run-usage", "0 archived runs")
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

    assert has_element?(view, "#agent-config-candidate-agent-launch", "Launch ready")
    assert has_element?(view, "#agent-config-candidate-agent-launch-summary", "exec sh")
    assert has_element?(view, "#agent-config-candidate-agent-launch-summary", "2 args")
    assert has_element?(view, "#agent-config-candidate-agent-launch-summary", "1 env key")

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

  test "surfaces accepted committed probe reports for saved agent configs", %{conn: conn} do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "codex-acp",
               executable: "sh",
               args: ["-c", "cat"]
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#agent-config-codex-acp-evidence", "3 accepted probes")
    assert has_element?(view, "#agent-config-codex-acp-accepted-probes")

    assert has_element?(
             view,
             "#agent-config-codex-acp-accepted-probe-codex-acp-basic",
             "docs/probes/codex-acp-basic.json"
           )

    assert has_element?(
             view,
             "#agent-config-codex-acp-accepted-probe-codex-acp-terminal-tool-call",
             "docs/probes/codex-acp-terminal-tool-call.json"
           )

    assert has_element?(
             view,
             "#agent-config-codex-acp-evidence-reason",
             "validated committed reports"
           )
  end

  test "shows blocked launch readiness for saved agent configs with missing executables", %{
    conn: conn
  } do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "missing-agent",
               executable: "definitely-not-a-real-haven-agent",
               args: ["--workspace", "{workspace}"],
               env: %{"SECRET" => "hidden-value"}
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#agent-config-missing-agent-launch", "Launch blocked")

    assert has_element?(
             view,
             "#agent-config-missing-agent-launch-summary",
             "Missing executable"
           )

    assert has_element?(view, "#agent-config-missing-agent-evidence", "Invalid command")
    assert has_element?(view, "#agent-config-missing-agent-evidence-reason", "executable")
    refute render(view) =~ "hidden-value"
  end

  test "shows blocked launch readiness for saved agent configs with missing cwd", %{
    conn: conn
  } do
    missing_cwd = Path.join(System.tmp_dir!(), "haven-missing-inbox-agent-cwd")
    File.rm_rf!(missing_cwd)

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "missing-cwd-agent",
               executable: "sh",
               cwd: missing_cwd
             })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#agent-config-missing-cwd-agent-launch", "Launch blocked")

    assert has_element?(
             view,
             "#agent-config-missing-cwd-agent-launch-summary",
             "Missing working directory"
           )

    assert has_element?(
             view,
             "#agent-config-missing-cwd-agent-evidence-reason",
             "working directory does not exist"
           )
  end

  @tag :tmp_dir
  test "rejects starting a run with a launch-blocked agent", %{conn: conn, tmp_dir: tmp_dir} do
    missing_cwd = Path.join(System.tmp_dir!(), "haven-missing-run-start-agent-cwd")
    File.rm_rf!(missing_cwd)

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "blocked-agent",
               executable: "sh",
               cwd: missing_cwd
             })

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#new-run-form", %{
        "title" => "Blocked agent run",
        "workspace" => tmp_dir,
        "agent" => "blocked-agent"
      })
      |> render_submit()

    assert html =~ "working directory is missing"
    assert has_element?(view, "#new-run-panel[open]")
    assert Runs.list_runs() == []
    refute_redirected(view)
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

  @tag :tmp_dir
  test "edits and deletes an agent config from the inbox", %{conn: conn, tmp_dir: tmp_dir} do
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

    assert {:ok, command} = Agents.command("edited-stub", tmp_dir)
    assert command.args == ["after", tmp_dir]
    assert command.cwd == tmp_dir
    assert command.env == [{"WORKSPACE", tmp_dir}]

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
    assert has_element?(view, ~s|#run-#{waiting.id}-title-link[href="/runs/#{waiting.id}"]|)
    assert has_element?(view, "#run-#{waiting.id}-attention", "Needs decision")

    assert has_element?(
             view,
             ~s|#run-#{waiting.id}-primary-action[href="/runs/#{waiting.id}"]|,
             "Decide"
           )

    assert has_element?(view, "article", "Still working")
    assert has_element?(view, "article", "Needs restart")
    assert has_element?(view, "#run-#{failed.id}-attention", "Needs recovery")
    assert has_element?(view, "#run-#{failed.id}-primary-action", "Recover")
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
  test "filters inbox runs by agent and workspace facets", %{conn: conn, tmp_dir: tmp_dir} do
    alpha_workspace = Path.join(tmp_dir, "alpha")
    beta_workspace = Path.join(tmp_dir, "beta")
    File.mkdir_p!(alpha_workspace)
    File.mkdir_p!(beta_workspace)

    insert_run!("Alpha docs", "waiting", %{workspace: alpha_workspace, agent: "codex-acp"})
    insert_run!("Alpha tests", "running", %{workspace: alpha_workspace, agent: "claude-acp"})
    insert_run!("Beta docs", "idle", %{workspace: beta_workspace, agent: "codex-acp"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s|#agent_filter option[value="codex-acp"]|)
    assert has_element?(view, ~s|#workspace_filter option[value="#{alpha_workspace}"]|)

    view
    |> form("#inbox-search-form", %{
      "agent_filter" => "codex-acp",
      "workspace_filter" => alpha_workspace,
      "run_search" => ""
    })
    |> render_change()

    assert has_element?(view, "article", "Alpha docs")
    refute has_element?(view, "article", "Alpha tests")
    refute has_element?(view, "article", "Beta docs")
    assert has_element?(view, "#inbox-filter-all", "1")
    assert has_element?(view, "#inbox-filter-needs_you", "1")
    assert has_element?(view, "#inbox-filter-running", "0")

    view
    |> form("#inbox-search-form", %{
      "agent_filter" => "codex-acp",
      "workspace_filter" => beta_workspace,
      "run_search" => "docs"
    })
    |> render_change()

    assert has_element?(view, "article", "Beta docs")
    refute has_element?(view, "article", "Alpha docs")

    view
    |> element("#clear-inbox-search")
    |> render_click()

    assert has_element?(view, "article", "Alpha docs")
    assert has_element?(view, "article", "Alpha tests")
    assert has_element?(view, "article", "Beta docs")
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

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "codex-acp",
               executable: "sh",
               args: ["-c", "cat"]
             })

    evidence_backed = insert_run!("Evidence backed", "idle", %{agent: "codex-acp"})

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "missing-agent",
               executable: "definitely-not-a-real-haven-agent"
             })

    blocked_agent = insert_run!("Broken command", "idle", %{agent: "missing-agent"})

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
    |> form("#inbox-search-form", %{"run_search" => "accepted probes"})
    |> render_change()

    assert has_element?(view, "#run-#{evidence_backed.id}", "Evidence backed")
    refute has_element?(view, "#run-#{blocked_agent.id}", "Broken command")
    refute has_element?(view, "article", "Docs cleanup")

    view
    |> form("#inbox-search-form", %{"run_search" => "launch blocked"})
    |> render_change()

    assert has_element?(view, "#run-#{blocked_agent.id}", "Broken command")
    refute has_element?(view, "#run-#{evidence_backed.id}", "Evidence backed")
    refute has_element?(view, "article", "Payment bug")

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

    assert has_element?(view, "#inbox-filter-empty", "No runs match your filters.")
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
    failed = insert_run!("Failed activity row", "failed")
    continued = insert_run!("Continued failure row", "running")

    Events.append!(run.id, "agent_message_chunk", %{
      "text" => "Reviewed the workspace\nand found one issue."
    })

    Events.append!(failed.id, "agent_start_failed", %{
      "reason" => "{:missing_cwd, \"/tmp/vanished\"}"
    })

    Events.append!(continued.id, "turn_continue_requested", %{
      "prompt" => "try a smaller plan after the protocol failure"
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#run-#{run.id}-latest-activity",
             "Agent: Reviewed the workspace and found one issue."
           )

    assert has_element?(
             view,
             "#run-#{failed.id}-latest-activity",
             "Agent start failed: {:missing_cwd, \"/tmp/vanished\"}"
           )

    assert has_element?(
             view,
             "#run-#{continued.id}-latest-activity",
             "Continue requested: try a smaller plan after the protocol failure"
           )

    view
    |> form("#inbox-search-form", %{"run_search" => "missing_cwd"})
    |> render_change()

    assert has_element?(view, "#run-#{failed.id}", "Failed activity row")
    refute has_element?(view, "#run-#{run.id}", "Activity row")
    refute has_element?(view, "#run-#{continued.id}", "Continued failure row")

    view
    |> form("#inbox-search-form", %{"run_search" => "smaller plan"})
    |> render_change()

    assert has_element?(view, "#run-#{continued.id}", "Continued failure row")
    refute has_element?(view, "#run-#{failed.id}", "Failed activity row")
  end

  test "renders and searches latest permission decisions with request context", %{conn: conn} do
    decided = insert_run!("Decision row", "idle")
    quiet = insert_run!("Quiet row", "idle")

    Events.append!(decided.id, "permission_requested", %{
      "request_id" => 7,
      "toolCall" => %{
        "title" => "Write file",
        "toolCallId" => "tool_7",
        "rawInput" => %{"path" => "notes/result.md"}
      },
      "options" => [
        %{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]
    })

    Events.append!(decided.id, "permission_resolved", %{
      "request_id" => 7,
      "option_id" => "allow",
      "outcome" => "selected",
      "actor" => "local_user"
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#run-#{decided.id}-latest-activity",
             "Decision recorded: allow for Write file"
           )

    view
    |> form("#inbox-search-form", %{"run_search" => "write file"})
    |> render_change()

    assert has_element?(view, "#run-#{decided.id}", "Decision row")
    refute has_element?(view, "#run-#{quiet.id}", "Quiet row")
  end

  test "labels inbox rows with operational process state", %{conn: conn} do
    disconnected = insert_run!("Disconnected history", "idle")
    stale_decision = insert_run!("Stale permission", "waiting")
    interrupted = insert_run!("Interrupted turn", "running")
    closed = insert_run!("Closed history", "closed")
    failed = insert_run!("Failed history", "failed")

    {:ok, live_run} = Runs.create_run(%{"title" => "Connected work"})
    stop_run_server_on_exit(live_run.id)
    sync_run_server!(live_run.id)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#run-#{disconnected.id}-operational-state", "Not connected")
    assert has_element?(view, "#run-#{disconnected.id}-operational-state", "reconnect")
    assert has_element?(view, "#run-#{stale_decision.id}-operational-state", "Stale decision")
    assert has_element?(view, "#run-#{interrupted.id}-operational-state", "Interrupted")
    assert has_element?(view, "#run-#{closed.id}-operational-state", "Read only")
    assert has_element?(view, "#run-#{closed.id} a", "Review")
    assert has_element?(view, "#run-#{failed.id}-operational-state", "Needs recovery")
    assert has_element?(view, "#run-#{live_run.id}-operational-state", "Ready")
  end

  test "searches inbox runs by operational state", %{conn: conn} do
    insert_run!("Disconnected history", "idle")
    insert_run!("Quiet history", "closed")

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#inbox-search-form", %{"run_search" => "not connected"})
    |> render_change()

    assert has_element?(view, "article", "Disconnected history")
    refute has_element?(view, "article", "Quiet history")
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
