defmodule HavenWeb.RunLiveTest do
  use HavenWeb.ConnCase

  alias Haven.Agents
  alias Haven.Events
  alias Haven.FileChanges
  alias Haven.PermissionAudits
  alias Haven.Repo
  alias Haven.Runs
  alias Haven.Runs.{Run, RunServer}
  alias Haven.TerminalSessions

  defp submit_prompt(view, prompt) do
    view
    |> form("#run-prompt-form", %{prompt: prompt})
    |> render_submit()
  end

  test "renders a durable run timeline after startup and reload", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Durable run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "run_created"
    assert html =~ "agent_process_started"
    assert html =~ "agent_initialized"
    assert html =~ "agent_session_started"
    assert has_element?(view, ~s|#event-1[data-event-kind="app"]|, "App")
    assert has_element?(view, ~s|#event-2[data-event-kind="runtime"]|, "Runtime")

    {:ok, _reloaded, reloaded_html} = live(conn, ~p"/runs/#{run.id}")

    assert reloaded_html =~ "Durable run"
    assert reloaded_html =~ "agent_session_started"
  end

  test "renders a conversation-first run thread with details disclosed on demand", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Thread first run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    run = Runs.get_run!(run.id)

    assert has_element?(view, ~s|#run-header-workspace[title="#{run.workspace}"]|)
    assert has_element?(view, "#run-header-workspace", Path.basename(run.workspace))
    assert has_element?(view, "#run-header-workspace-path", Path.dirname(run.workspace))
    refute has_element?(view, "#run-header-facts")
    assert has_element?(view, "#run-facts-agent", "stub-acp")
    assert has_element?(view, "#run-facts-agent-launch", "Launch ready")
    assert has_element?(view, "#run-facts-agent-trust", "Local harness")
    assert has_element?(view, "#run-facts-agent-evidence-reason", "built-in stub-acp")
    assert has_element?(view, "#run-facts-agent-cwd", "cwd app default")
    assert has_element?(view, "#run-facts-agent-env-keys", "env none")
    assert has_element?(view, "#run-facts-session", run.agent_session_id)
    assert has_element?(view, "#run-facts-created")
    assert has_element?(view, "#run-facts-updated")
    assert has_element?(view, "#run-evidence-summary")
    assert has_element?(view, "#run-evidence-events", "4")
    assert has_element?(view, "#run-evidence-decisions", "0")
    assert has_element?(view, "#run-evidence-file-changes", "0")
    assert has_element?(view, "#run-evidence-terminal-sessions", "0")
    assert has_element?(view, "#run-section-nav")
    assert has_element?(view, ~s|#run-nav-thread[href="#run-thread"]|, "Thread")
    assert has_element?(view, "#run-nav-thread-count", "0")
    assert has_element?(view, ~s|#run-nav-decisions[href="#run-permission-audit"]|, "Decisions")
    assert has_element?(view, "#run-nav-decisions-count", "0")
    assert has_element?(view, ~s|#run-nav-message[href="#run-control-panel"]|, "Message")
    assert has_element?(view, ~s|#run-nav-evidence[href="#run-evidence-summary"]|, "Evidence")
    assert has_element?(view, "#run-nav-evidence-count", "4")
    assert has_element?(view, "#run-thread")
    assert has_element?(view, "#timeline-filters summary", "Filter activity")
    assert has_element?(view, "#run-control-panel", "Message")
    assert has_element?(view, "#run-control-panel.sticky")
    assert has_element?(view, "#run-prompt-form")
    refute has_element?(view, "#sample-prompts-disclosure")
    assert has_element?(view, "#run-capability-policy summary", "Capability policy")
    assert has_element?(view, "#run-permission-audit summary", "Permission audit")
    assert has_element?(view, "#run-file-changes summary", "File changes")
    assert has_element?(view, "#run-terminal-sessions summary", "Terminal sessions")

    html = render(view)
    assert html =~ "lg:grid-cols-[minmax(0,1fr)_320px]"
    assert html =~ "min-w-0 space-y-4"
    refute html =~ "md:grid-cols-[minmax(0,1fr)_320px]"

    prompt_index = :binary.match(html, ~s|id="run-prompt-form"|) |> elem(0)
    filters_index = :binary.match(html, ~s|id="timeline-filters"|) |> elem(0)
    facts_index = :binary.match(html, ~s|id="run-capability-policy"|) |> elem(0)

    assert prompt_index < filters_index
    assert filters_index < facts_index
  end

  @tag :tmp_dir
  test "renders run-specific configured agent launch scope without env values", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    agent_cwd = Path.join(tmp_dir, "agent-workspace")
    File.mkdir_p!(agent_cwd)

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "scoped-run-agent",
               executable: "sh",
               args: ["-c", "cat"],
               cwd: "{workspace}",
               env: %{
                 "TOKEN" => "hidden-run-token",
                 "WORKSPACE" => "{workspace}"
               }
             })

    run =
      %Run{}
      |> Run.changeset(%{
        title: "Scoped agent run",
        agent: "scoped-run-agent",
        workspace: agent_cwd,
        status: "idle",
        agent_session_id: "saved-session"
      })
      |> Repo.insert!()

    Events.append!(run.id, "run_created", %{
      "title" => run.title,
      "workspace" => run.workspace,
      "agent" => run.agent
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-facts-agent", "scoped-run-agent")
    assert has_element?(view, "#run-facts-agent-launch", "Launch ready")
    assert has_element?(view, "#run-facts-agent-cwd", "cwd #{Path.expand(agent_cwd)}")
    assert has_element?(view, "#run-facts-agent-env-keys", "env keys TOKEN, WORKSPACE")

    refute render(view) =~ "hidden-run-token"
  end

  test "mounting run detail reuses the loaded run when checking liveness", %{conn: conn} do
    run = insert_disconnected_run!("Loaded detail liveness")
    parent = self()
    telemetry_id = "run-live-loaded-liveness-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:haven, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:repo_query, metadata})
        end,
        nil
      )

    try do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#haven-run")

      run_selects =
        collect_repo_queries()
        |> Enum.filter(fn metadata ->
          metadata[:source] == "runs" and String.starts_with?(metadata[:query], "SELECT")
        end)

      assert length(run_selects) <= 2
    after
      :telemetry.detach(telemetry_id)
    end
  end

  test "renders accepted real-agent evidence in run details", %{conn: conn} do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "codex-acp",
               executable: "sh",
               args: ["-c", "cat"]
             })

    run = insert_run!("Evidence-backed run", "codex-acp")

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    refute has_element?(view, "#run-header-agent")
    assert has_element?(view, "#run-facts-agent", "codex-acp")
    assert has_element?(view, "#run-facts-agent-launch", "Launch ready")
    assert has_element?(view, "#run-facts-agent-trust", "5 accepted probes")
    assert has_element?(view, "#run-facts-agent-capability-gaps", "3 capability gaps")

    assert has_element?(
             view,
             "#run-facts-agent-evidence-reason",
             "validated committed reports"
           )

    assert has_element?(
             view,
             "#run-facts-agent-capability-gap-reason",
             "not Haven-mediated file/terminal handling"
           )

    assert has_element?(view, "#run-agent-probe-evidence", "Accepted probe artifacts")
    assert has_element?(view, "#run-agent-capability-gap-evidence", "Capability gap reports")

    assert has_element?(
             view,
             "#run-agent-probe-codex-acp-basic",
             "docs/probes/codex-acp-basic.json"
           )

    assert has_element?(
             view,
             "#run-agent-probe-codex-acp-terminal-tool-call",
             "docs/probes/codex-acp-terminal-tool-call.json"
           )

    assert has_element?(
             view,
             "#run-agent-capability-gap-codex-acp-file-mediated-negative",
             "docs/probe-failures/codex-acp-file-mediated-negative.json"
           )

    assert has_element?(
             view,
             "#run-agent-capability-gap-codex-acp-file-write-mediated-negative",
             "file_write_requested"
           )

    assert has_element?(
             view,
             "#run-agent-capability-gap-codex-acp-terminal-mediated-negative",
             "terminal_create_requested"
           )
  end

  test "ignores global inbox activity notifications while using run-scoped events", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Scoped event run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    Events.append!(run.id, "agent_message_chunk", %{"text" => "Scoped event update"})

    assert has_element?(view, "#run-thread", "Scoped event update")
  end

  test "renders the run capability policy in the facts panel", %{conn: conn} do
    {:ok, run} =
      Runs.create_run(%{
        "title" => "Policy facts run",
        "capability_policy" => %{
          "file_read" => "allow",
          "file_read_paths" => ["README.md", "docs"],
          "file_write" => "ask",
          "file_write_paths" => ["notes"],
          "terminal_create" => "deny"
        }
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-capability-policy")
    assert has_element?(view, "#run-policy-file-read", "Allow")
    assert has_element?(view, "#run-policy-file-read-scope-readme-md", "README.md")
    assert has_element?(view, "#run-policy-file-read-scope-docs", "docs")
    assert has_element?(view, "#run-policy-file-read-paths span", "README.md")
    assert has_element?(view, "#run-policy-file-read-paths span", "docs")
    assert has_element?(view, "#run-policy-file-write", "Ask")
    assert has_element?(view, "#run-policy-file-write-scope-notes", "notes")
    assert has_element?(view, "#run-policy-file-write-paths span", "notes")
    assert has_element?(view, "#run-policy-terminal-create", "Deny")
    assert has_element?(view, "#run-security-boundary", "Workspace security boundary")
    assert has_element?(view, "#run-security-boundary-root", "workspace root")
    assert has_element?(view, "#run-security-boundary-scopes", "Blank path scopes")
    assert has_element?(view, "#run-security-boundary-terminal", "inside the workspace")
    assert has_element?(view, "#run-terminal-sessions")
    assert has_element?(view, "#run-terminal-session-count", "0")
    assert has_element?(view, "#run-terminal-sessions-empty", "No terminal sessions recorded.")
  end

  test "renders unrestricted capability scopes as explicit policy chips", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Unrestricted policy run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-policy-file-read-scope-all-workspace-paths")
    assert has_element?(view, "#run-policy-file-write-scope-all-workspace-paths")
    assert has_element?(view, "#run-policy-file-read-paths span", "All workspace paths")
    assert has_element?(view, "#run-policy-file-write-paths span", "All workspace paths")
  end

  test "viewing disconnected idle history does not spawn a new agent process", %{conn: conn} do
    run = insert_disconnected_run!("Disconnected history")

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "Disconnected history"
    assert html =~ "not connected"
    assert has_element?(view, "#send-prompt-button[disabled]")
    assert has_element?(view, ~s|#send-prompt-button[title*="not connected"]|)
    assert has_element?(view, ~s|#cancel-run-button[title*="no live turn"]|)
    assert has_element?(view, "#run-control-notice", "not connected")
    refute has_element?(view, "#run-control-panel.sticky")
    refute Runs.started?(run.id)

    events = Events.list_for_run(run.id)
    refute Enum.any?(events, &(&1.type == "agent_process_started"))
    refute Enum.any?(events, &(&1.type == "user_message"))
  end

  test "explicit reconnect starts a new process for disconnected idle history", %{conn: conn} do
    run = insert_disconnected_run!("Reconnect history")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-recovery-card", "Run is not connected")
    assert has_element?(view, "#run-recovery-action-button", "Reconnect")
    assert has_element?(view, "#reconnect-run-button", "Reconnect")

    view
    |> element("#run-recovery-action-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "idle"}
                    }},
                   1_000

    wait_for_event!(run.id, "agent_process_started")
    wait_for_event!(run.id, "agent_session_started")
    wait_for_idle_session!(run.id)

    html = render(view)
    assert html =~ "connected"
    assert has_element?(view, "#send-prompt-button:not([disabled])")
  end

  test "reconnect system-cancels stale pending permissions for disconnected waiting runs", %{
    conn: conn
  } do
    run = insert_disconnected_run!("Reconnect waiting history", "waiting")
    append_permission_requested!(run.id, 42)
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    [pending_audit] = PermissionAudits.list_for_run(run.id)
    assert pending_audit.status == "pending"
    assert pending_audit.request_id == 42

    assert html =~ "not connected"
    assert has_element?(view, "#pending-permission-card", "Write file")
    assert has_element?(view, ~s|#pending-permission-card button[disabled]|)
    assert has_element?(view, "#run-control-notice", "not connected")
    assert has_element?(view, "#reconnect-run-button", "Reconnect")
    refute Runs.started?(run.id)

    view
    |> element("#reconnect-run-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "waiting"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => 42,
                        "option_id" => "cancelled",
                        "outcome" => "cancelled",
                        "reason" => "run_reconnect_requested",
                        "actor" => "system"
                      }
                    }},
                   1_000

    wait_for_event!(run.id, "agent_process_started")
    wait_for_event!(run.id, "agent_session_started")
    wait_for_idle_session!(run.id)

    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "connected"

    [cancelled_audit] = PermissionAudits.list_for_run(run.id)
    assert cancelled_audit.status == "cancelled"
    assert cancelled_audit.selected_option_id == "cancelled"
    assert cancelled_audit.outcome == "cancelled"
    assert cancelled_audit.reason == "run_reconnect_requested"
    assert cancelled_audit.actor == "system"
  end

  test "renders malformed pending permission requests as inspectable instead of crashing", %{
    conn: conn
  } do
    run = insert_disconnected_run!("Malformed permission request", "waiting")

    Events.append!(run.id, "permission_requested", %{
      "request_id" => "broken-permission",
      "toolCall" => %{
        "rawInput" => %{"path" => "notes/plan.md"},
        "title" => "Write file"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#pending-permission-card", "Write file")
    assert has_element?(view, "#pending-permission-missing-options", "valid decision options")
    assert has_element?(view, "#pending-permission-options", "none")
    assert has_element?(view, "#pending-permission-request-id", "broken-permission")
    assert has_element?(view, "#pending-permission-primary-actions", "Cancel turn")
    refute has_element?(view, ~s|#pending-permission-primary-actions button[phx-value-option-id]|)
  end

  test "reconnect fails stale in-flight turns for disconnected running runs", %{conn: conn} do
    run = insert_disconnected_run!("Reconnect running history", "running")
    Events.append!(run.id, "turn_started", %{"prompt" => "still running"})
    Events.append!(run.id, "user_message", %{"text" => "still running"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "not connected"
    assert has_element?(view, "#reconnect-run-button", "Reconnect")
    assert has_element?(view, "#send-prompt-button[disabled]")
    assert has_element?(view, "#run-control-notice", "not connected")
    refute has_element?(view, "#run-control-notice", "A turn is already in progress")
    refute Runs.started?(run.id)

    view
    |> element("#reconnect-run-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "running"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "turn_failed",
                      payload: %{
                        "error" => "run_reconnect_requested",
                        "actor" => "system"
                      }
                    }},
                   1_000

    wait_for_event!(run.id, "agent_process_started")
    wait_for_event!(run.id, "agent_session_started")
    wait_for_idle_session!(run.id)

    assert has_element?(view, "#event-5", "Reconnect requested")
    assert has_element?(view, "#event-5", "Previous status: running")
    assert has_element?(view, "#event-6", "Turn failed")
    assert has_element?(view, "#event-6", "run_reconnect_requested")
    assert has_element?(view, "#event-6", "system")
    assert render(view) =~ "connected"
    assert has_element?(view, "#send-prompt-button:not([disabled])")

    view
    |> form("#run-prompt-form", %{"prompt" => "after reconnect"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_started"}}, 1_000

    assert_receive {:event_appended,
                    %{type: "user_message", payload: %{"text" => "after reconnect"}}},
                   1_000

    assert_receive {:event_appended,
                    %{type: "agent_message_chunk", payload: %{"text" => "Echo: after reconnect"}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    html = render(view)
    assert html =~ "still running"
    assert html =~ "Reconnect requested"
    assert html =~ "Turn failed"
    assert html =~ "after reconnect"
    assert html =~ "Echo: after reconnect"
  end

  test "explicit restart starts a new process for failed runs", %{conn: conn} do
    run = insert_disconnected_run!("Restart failed history", "failed")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "failed"
    assert has_element?(view, "#run-recovery-card", "Run failed")
    assert has_element?(view, "#run-recovery-action-button", "Restart")
    assert has_element?(view, "#reconnect-run-button", "Restart")
    assert has_element?(view, "#run-control-notice", "Restart it before sending another prompt.")
    refute has_element?(view, "#retry-last-prompt-button")

    view
    |> element("#run-recovery-action-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "failed"}
                    }},
                   1_000

    wait_for_event!(run.id, "agent_process_started")
    wait_for_event!(run.id, "agent_session_started")
    wait_for_idle_session!(run.id)

    assert render(view) =~ "connected"
  end

  test "retry last prompt restarts a failed run and resubmits the prompt", %{conn: conn} do
    run = insert_disconnected_run!("Retry failed history", "failed")
    Events.append!(run.id, "turn_started", %{"prompt" => "retry me"})
    Events.append!(run.id, "user_message", %{"text" => "retry me"})
    Events.append!(run.id, "turn_failed", %{"error" => "agent_process_exited"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-recovery-card", "Run failed")
    assert has_element?(view, "#retry-last-prompt-button", "Retry last prompt")
    assert has_element?(view, "#retry-last-prompt-preview", "retry me")
    assert has_element?(view, "#run-recovery-action-button", "Restart")

    view
    |> element("#retry-last-prompt-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "failed"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    assert_receive {:event_appended,
                    %{type: "turn_retry_requested", payload: %{"prompt" => "retry me"}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_started", payload: %{"prompt" => "retry me"}}},
                   1_000

    assert_receive {:event_appended, %{type: "user_message", payload: %{"text" => "retry me"}}},
                   1_000

    assert_receive {:event_appended,
                    %{type: "agent_message_chunk", payload: %{"text" => "Echo: retry me"}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    wait_for_idle_session!(run.id)

    html = render(view)
    assert html =~ "Retry requested"
    assert html =~ "Echo: retry me"
    assert html =~ "idle"
    refute has_element?(view, "#retry-last-prompt-button")
  end

  test "continue with a new prompt restarts a failed run and preserves history", %{conn: conn} do
    run = insert_disconnected_run!("Continue failed history", "failed")
    Events.append!(run.id, "turn_started", %{"prompt" => "old failed prompt"})
    Events.append!(run.id, "user_message", %{"text" => "old failed prompt"})
    Events.append!(run.id, "turn_failed", %{"error" => "agent_protocol_failed"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-recovery-card", "Run failed")
    assert has_element?(view, "#continue-after-failure-form")
    assert has_element?(view, "#continue-after-failure-button", "Continue with new prompt")

    view
    |> form("#continue-after-failure-form", %{"prompt" => "try a different approach"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "failed"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    assert_receive {:event_appended,
                    %{
                      type: "turn_continue_requested",
                      payload: %{"prompt" => "try a different approach"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{type: "turn_started", payload: %{"prompt" => "try a different approach"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "user_message",
                      payload: %{"text" => "try a different approach"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Echo: try a different approach"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    wait_for_idle_session!(run.id)

    html = render(view)
    assert html =~ "old failed prompt"
    assert html =~ "Continue requested"
    assert html =~ "Echo: try a different approach"
    assert html =~ "idle"
    refute has_element?(view, "#continue-after-failure-form")
  end

  test "closed runs render as read-only history with disabled controls", %{conn: conn} do
    run = insert_disconnected_run!("Closed history", "closed")

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "closed"
    assert has_element?(view, "#send-prompt-button[disabled]")
    assert has_element?(view, "#cancel-run-button[disabled]")
    assert has_element?(view, ~s|#send-prompt-button[title*="closed"]|)
    assert has_element?(view, ~s|#cancel-run-button[title*="no active turn"]|)
    assert has_element?(view, "#run-control-notice", "closed")
    refute has_element?(view, "#reconnect-run-button")
    refute Runs.started?(run.id)
  end

  test "archived runs render as review-only history without recovery controls", %{conn: conn} do
    run = insert_disconnected_run!("Archived failed history", "failed")
    assert {:ok, archived_run} = Runs.archive_run(run.id)

    {:ok, view, html} = live(conn, ~p"/runs/#{archived_run.id}")

    assert html =~ "failed"
    assert has_element?(view, "#run-header-archive-state", "Archived")
    assert has_element?(view, ~s|#run-header-archive-state[title*="Archived at"]|)
    assert has_element?(view, "#run-archive-card", "Archived history")
    assert has_element?(view, "#run-control-notice", "archived")
    assert has_element?(view, "#send-prompt-button[disabled]")
    assert has_element?(view, "#cancel-run-button[disabled]")
    assert has_element?(view, ~s|#send-prompt-button[title*="archived"]|)
    assert has_element?(view, ~s|#cancel-run-button[title*="archived"]|)
    refute has_element?(view, "#run-recovery-card")
    refute has_element?(view, "#run-recovery-action-button")
    refute has_element?(view, "#retry-last-prompt-button")
    refute has_element?(view, "#continue-after-failure-form")
    refute has_element?(view, "#reconnect-run-button")
    refute Runs.started?(archived_run.id)
  end

  test "sends a prompt and appends user and agent turn events", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Prompt run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    refute has_element?(view, "#run-control-notice")
    refute has_element?(view, "#send-prompt-button[title]")
    assert has_element?(view, ~s|#cancel-run-button[title*="no active turn"]|)

    view
    |> form("#run-prompt-form", %{"prompt" => "hello from LiveView"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_started"}}, 1_000

    assert_receive {:event_appended,
                    %{type: "user_message", payload: %{"text" => "hello from LiveView"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Echo: hello from LiveView"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    assert render(view) =~ "Echo: hello from LiveView"
    assert has_element?(view, ~s|[data-event-kind="user"]|, "User")
    assert has_element?(view, ~s|[data-event-kind="agent"]|, "Agent")
    assert render(view) =~ "idle"
  end

  test "filters timeline events by provenance", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Filtered timeline run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "hello from filter test"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    assert has_element?(view, "#timeline-filters")
    assert has_element?(view, "#timeline-filter-agent")

    view
    |> element("#timeline-filter-agent")
    |> render_click()

    assert has_element?(view, ~s|[data-event-kind="agent"]|, "Agent")
    assert render(view) =~ "Echo: hello from filter test"
    refute has_element?(view, ~s|[data-event-kind="user"]|)
    refute has_element?(view, ~s|[data-event-kind="runtime"]|)

    view
    |> element("#timeline-filter-runtime")
    |> render_click()

    assert has_element?(view, ~s|[data-event-kind="runtime"]|, "Runtime")
    refute has_element?(view, ~s|[data-event-kind="agent"]|, "Echo: hello from filter test")
    refute has_element?(view, ~s|[data-event-kind="agent"]|)
    assert has_element?(view, "#run-conversation", "Echo: hello from filter test")

    view
    |> element("#timeline-filter-all")
    |> render_click()

    assert has_element?(view, ~s|[data-event-kind="runtime"]|, "Runtime")
    assert has_element?(view, ~s|[data-event-kind="agent"]|, "Agent")
    assert has_element?(view, ~s|[data-event-kind="user"]|, "User")
  end

  test "renders a compact turn summary from durable events", %{conn: conn} do
    run = insert_disconnected_run!("Turn summary history", "failed")

    Events.append!(run.id, "turn_started", %{"prompt" => "ship the first slice"})
    Events.append!(run.id, "user_message", %{"text" => "ship the first slice"})
    Events.append!(run.id, "agent_message_chunk", %{"text" => "First slice shipped."})
    Events.append!(run.id, "tool_call", %{"toolCallId" => "tool-1", "title" => "Inspect repo"})
    Events.append!(run.id, "turn_finished", %{})
    Events.append!(run.id, "turn_started", %{"prompt" => "try the risky path"})
    Events.append!(run.id, "user_message", %{"text" => "try the risky path"})

    Events.append!(run.id, "permission_requested", %{
      "options" => [%{"kind" => "allow_once", "name" => "Allow once", "optionId" => "allow"}],
      "request_id" => "perm-1",
      "toolCall" => %{"rawInput" => %{"path" => "notes/plan.md"}, "title" => "Write file"}
    })

    Events.append!(run.id, "file_write_requested", %{"path" => "notes/plan.md"})
    Events.append!(run.id, "turn_failed", %{"error" => "agent_process_exited"})

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-turn-summary")
    assert has_element?(view, "#run-turn-summary-count", "2")

    assert has_element?(view, ~s|#run-turn-3[data-turn-status="completed"]|, "Completed")
    assert has_element?(view, "#run-turn-3", "ship the first slice")
    assert has_element?(view, "#run-turn-3-agent-preview", "First slice shipped.")
    assert has_element?(view, "#run-turn-3-tool-calls", "1")

    assert has_element?(view, ~s|#run-turn-8[data-turn-status="failed"]|, "Failed")
    assert has_element?(view, "#run-turn-8", "try the risky path")
    assert has_element?(view, "#run-turn-8-decisions", "1")
    assert has_element?(view, "#run-turn-8-files", "1")
    assert has_element?(view, "#run-turn-8-error", "agent_process_exited")
  end

  test "searches timeline events without mutating event history", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Timeline search run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "find quartz evidence"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    assert has_element?(view, "#timeline-search-form")
    assert has_element?(view, "#event_search")

    view
    |> form("#timeline-search-form", %{"event_search" => "quartz"})
    |> render_change()

    assert has_element?(view, ~s|[data-event-kind="user"]|, "User")
    assert render(view) =~ "find quartz evidence"
    refute has_element?(view, ~s|[data-event-kind="runtime"]|)

    view
    |> form("#timeline-search-form", %{"event_search" => "not-present"})
    |> render_change()

    assert has_element?(view, "#timeline-empty-filter", "No events match this search.")
    refute has_element?(view, ~s|[data-event-kind="user"]|, "find quartz evidence")
    assert has_element?(view, "#run-conversation", "find quartz evidence")

    view
    |> element("#clear-timeline-search")
    |> render_click()

    assert has_element?(view, ~s|[data-event-kind="runtime"]|, "Runtime")
    assert has_element?(view, ~s|[data-event-kind="user"]|, "User")
    assert length(Events.list_for_run(run.id)) > 1
  end

  test "searches timeline by rendered event labels", %{conn: conn} do
    run = insert_run!("Timeline label search run", "stub-acp")

    protocol_failure =
      Events.append!(run.id, "agent_protocol_failed", %{
        "reason" => "malformed_agent_output",
        "agent" => "stub-acp",
        "workspace" => run.workspace
      })

    continue_request =
      Events.append!(run.id, "turn_continue_requested", %{
        "prompt" => "try another route"
      })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#timeline-search-form", %{"event_search" => "protocol failed"})
    |> render_change()

    assert has_element?(view, "#runtime-failure-#{protocol_failure.seq}", "Agent protocol failed")
    refute has_element?(view, "#event-#{continue_request.seq}")

    view
    |> form("#timeline-search-form", %{"event_search" => "continue requested"})
    |> render_change()

    assert has_element?(view, "#event-#{continue_request.seq}", "Continue requested")
    refute has_element?(view, "#runtime-failure-#{protocol_failure.seq}")
  end

  test "renders ACP file tool calls as reviewable timeline evidence", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "File tool call projection"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    Events.append!(run.id, "tool_call", %{
      "kind" => "read",
      "locations" => [%{"path" => "/workspace/README.md"}],
      "status" => "in_progress",
      "title" => "Read file '/workspace/README.md'",
      "toolCallId" => "call_file"
    })

    Events.append!(run.id, "tool_call_update", %{
      "rawOutput" => %{
        "exit_code" => 0,
        "formatted_output" => "Grei file sentinel: quartz-lantern-729\n"
      },
      "status" => "completed",
      "toolCallId" => "call_file"
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, ~s|#event-5[data-event-kind="protocol"]|, "Protocol")
    assert has_element?(view, "#event-5", "#5-6 · tool_call + tool_call_update")
    refute has_element?(view, "#event-6")
    assert has_element?(view, "#tool-call-path", "/workspace/README.md")
    assert has_element?(view, "#tool-call-status", "in_progress")
    assert has_element?(view, "#tool-call-result-5")
    assert render(view) =~ "File read"
    assert render(view) =~ "Completed successfully"
    assert has_element?(view, "#tool-result-output", "Grei file sentinel: quartz-lantern-729")

    view
    |> form("#timeline-search-form", %{"event_search" => "quartz-lantern-729"})
    |> render_change()

    assert has_element?(view, "#event-5", "#5-6 · tool_call + tool_call_update")
    refute has_element?(view, "#event-6")
    assert has_element?(view, "#tool-result-output", "Grei file sentinel: quartz-lantern-729")
  end

  test "renders ACP terminal tool calls with command output and exit status", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Terminal tool call projection"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    Events.append!(run.id, "tool_call", %{
      "_meta" => %{
        "terminal_info" => %{
          "cwd" => "/workspace",
          "terminal_id" => "call_terminal"
        }
      },
      "kind" => "execute",
      "rawInput" => %{
        "command" => "printf 'Grei terminal sentinel: amber-harbor-314\\n'",
        "cwd" => "/workspace"
      },
      "status" => "in_progress",
      "title" => "printf 'Grei terminal sentinel: amber-harbor-314\\n'",
      "toolCallId" => "call_terminal"
    })

    Events.append!(run.id, "tool_call_update", %{
      "_meta" => %{
        "terminal_exit" => %{"exit_code" => 0, "terminal_id" => "call_terminal"},
        "terminal_output_delta" => %{
          "data" => "Grei terminal sentinel: amber-harbor-314\n",
          "terminal_id" => "call_terminal"
        }
      },
      "status" => "completed",
      "toolCallId" => "call_terminal"
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, ~s|#event-5[data-event-kind="protocol"]|, "Protocol")
    assert has_element?(view, "#event-5", "#5-6 · tool_call + tool_call_update")
    refute has_element?(view, "#event-6")
    assert render(view) =~ "Terminal"
    assert has_element?(view, "#tool-call-command", "printf")
    assert has_element?(view, "#tool-call-cwd", "/workspace")
    assert has_element?(view, "#tool-call-result-5")
    assert has_element?(view, "#tool-result-exit-code", "0")
    assert has_element?(view, "#tool-result-output", "Grei terminal sentinel: amber-harbor-314")
  end

  test "renders Haven-mediated file capability events as structured timeline evidence", %{
    conn: conn
  } do
    {:ok, run} = Runs.create_run(%{"title" => "File client event projection"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    Events.append!(run.id, "file_write_requested", %{
      "bytes" => 21,
      "path" => "notes/handoff.md",
      "session_id" => "session_file"
    })

    Events.append!(run.id, "file_write_succeeded", %{
      "path" => "notes/handoff.md",
      "resolved_path" => "/workspace/notes/handoff.md",
      "session_id" => "session_file"
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, ~s|#event-5[data-event-kind="client"]|, "Client request")
    assert has_element?(view, "#event-5", "Write file")
    assert has_element?(view, "#event-5", "Requested")
    assert has_element?(view, "#client-event-5-path", "notes/handoff.md")
    assert has_element?(view, "#client-event-5-bytes", "21")
    assert has_element?(view, "#event-6", "Succeeded")
    assert has_element?(view, "#client-event-6-resolved-path", "/workspace/notes/handoff.md")
  end

  test "renders Haven-mediated terminal capability events as structured timeline evidence", %{
    conn: conn
  } do
    {:ok, run} = Runs.create_run(%{"title" => "Terminal client event projection"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)

    Events.append!(run.id, "terminal_create_requested", %{
      "args" => ["hello"],
      "command" => "echo",
      "cwd" => "/workspace",
      "session_id" => "session_terminal"
    })

    Events.append!(run.id, "terminal_output_succeeded", %{
      "bytes" => 6,
      "exit_status" => 0,
      "session_id" => "session_terminal",
      "terminal_id" => "term-123"
    })

    Events.append!(run.id, "terminal_released", %{
      "session_id" => "session_terminal",
      "terminal_id" => "term-123"
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, ~s|#event-5[data-event-kind="client"]|, "Client request")
    assert has_element?(view, "#event-5", "Create terminal")
    assert has_element?(view, "#client-event-5-command", "echo")
    assert has_element?(view, "#client-event-5-args", "hello")
    assert has_element?(view, "#client-event-5-cwd", "/workspace")
    assert has_element?(view, "#event-6", "Read terminal output")
    assert has_element?(view, "#client-event-6-terminal-id", "term-123")
    assert has_element?(view, "#client-event-6-exit-status", "0")
    assert has_element?(view, "#client-event-6-bytes", "6")
    assert has_element?(view, "#event-7", "Release terminal")
    assert has_element?(view, "#event-7", "Released")
  end

  test "keeps concurrent live runs isolated", %{conn: conn} do
    {:ok, alpha} = Runs.create_run(%{"title" => "Alpha run"})
    {:ok, beta} = Runs.create_run(%{"title" => "Beta run"})
    stop_run_server_on_exit(alpha.id)
    stop_run_server_on_exit(beta.id)
    wait_for_idle_session!(alpha.id)
    wait_for_idle_session!(beta.id)
    Events.subscribe(alpha.id)
    Events.subscribe(beta.id)

    {:ok, alpha_view, _html} = live(conn, ~p"/runs/#{alpha.id}")
    {:ok, beta_view, _html} = live(conn, ~p"/runs/#{beta.id}")

    alpha_task = Task.async(fn -> Runs.send_prompt(alpha.id, "alpha only") end)
    beta_task = Task.async(fn -> Runs.send_prompt(beta.id, "beta only") end)

    assert Task.await(alpha_task, 1_000) == :ok
    assert Task.await(beta_task, 1_000) == :ok

    assert_receive {:event_appended,
                    %{
                      run_id: alpha_run_id,
                      type: "agent_message_chunk",
                      payload: %{"text" => "Echo: alpha only"}
                    }},
                   1_000

    assert alpha_run_id == alpha.id

    assert_receive {:event_appended,
                    %{
                      run_id: beta_run_id,
                      type: "agent_message_chunk",
                      payload: %{"text" => "Echo: beta only"}
                    }},
                   1_000

    assert beta_run_id == beta.id

    assert_receive {:event_appended, %{run_id: ^alpha_run_id, type: "turn_finished"}}, 1_000
    assert_receive {:event_appended, %{run_id: ^beta_run_id, type: "turn_finished"}}, 1_000

    alpha_html = render(alpha_view)
    beta_html = render(beta_view)

    assert alpha_html =~ "Echo: alpha only"
    refute alpha_html =~ "Echo: beta only"
    assert beta_html =~ "Echo: beta only"
    refute beta_html =~ "Echo: alpha only"

    alpha_events = Events.list_for_run(alpha.id)
    beta_events = Events.list_for_run(beta.id)

    assert Enum.any?(alpha_events, &(&1.payload["text"] == "Echo: alpha only"))
    refute Enum.any?(alpha_events, &(&1.payload["text"] == "Echo: beta only"))
    assert Enum.any?(beta_events, &(&1.payload["text"] == "Echo: beta only"))
    refute Enum.any?(beta_events, &(&1.payload["text"] == "Echo: alpha only"))

    assert Runs.get_run!(alpha.id).status == "idle"
    assert Runs.get_run!(beta.id).status == "idle"
  end

  test "surfaces and resolves exact permission requests", %{conn: conn} do
    {:ok, run} =
      Runs.create_run(%{
        "title" => "Permission run",
        "capability_policy" => %{
          "file_read" => "allow",
          "file_read_paths" => ["README.md", "docs"],
          "file_write" => "ask",
          "file_write_paths" => ["notes"],
          "terminal_create" => "deny"
        }
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "permission")

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    html = render(view)
    assert html =~ "Needs approval"
    assert html =~ "Write file"
    assert has_element?(view, "#pending-permission-card")

    assert has_element?(
             view,
             ~s|#run-nav-decisions[href="#pending-permission-card"]|,
             "Decisions"
           )

    assert has_element?(view, "#run-nav-decisions-count", "1")
    assert has_element?(view, "#pending-permission-conversation-context", "Prompt context")
    assert has_element?(view, "#pending-permission-conversation-context", "permission")
    assert has_element?(view, "#pending-permission-decision-summary")

    assert has_element?(
             view,
             "#pending-permission-decision-action",
             "Review the requested file write."
           )

    assert has_element?(
             view,
             "#pending-permission-decision-consequence",
             "Allow lets the agent proceed with this write request; deny blocks it."
           )

    assert has_element?(view, "#pending-permission-primary-actions")
    assert has_element?(view, "#pending-permission-primary-actions button", "Allow once")
    assert has_element?(view, "#pending-permission-primary-actions button", "Deny")
    assert has_element?(view, "#pending-permission-primary-actions", "Cancel turn")
    assert has_element?(view, "#pending-permission-details:not([open])")
    assert has_element?(view, "#pending-permission-details summary", "Review details")

    summary_index = :binary.match(html, ~s|id="pending-permission-decision-summary"|) |> elem(0)
    actions_index = :binary.match(html, ~s|id="pending-permission-primary-actions"|) |> elem(0)
    details_index = :binary.match(html, ~s|id="pending-permission-details"|) |> elem(0)
    authority_index = :binary.match(html, ~s|id="pending-permission-authority"|) |> elem(0)

    assert summary_index < actions_index
    assert actions_index < details_index
    assert details_index < authority_index

    assert has_element?(view, "#pending-permission-request-id", to_string(request_id))
    assert has_element?(view, "#pending-permission-tool-call-id", "tool_#{request_id}")
    assert has_element?(view, "#pending-permission-tool-status", "pending")
    assert has_element?(view, "#pending-permission-options", "Allow once (allow)")
    assert has_element?(view, "#pending-permission-options", "Deny (deny)")
    assert has_element?(view, "#pending-permission-authority")
    assert has_element?(view, "#pending-permission-authority-read", "Allow")
    assert has_element?(view, "#pending-permission-read-scope-readme-md", "README.md")
    assert has_element?(view, "#pending-permission-read-scope-docs", "docs")
    assert has_element?(view, "#pending-permission-authority-read span", "README.md")
    assert has_element?(view, "#pending-permission-authority-read span", "docs")
    assert has_element?(view, "#pending-permission-authority-write", "Ask")
    assert has_element?(view, "#pending-permission-write-scope-notes", "notes")
    assert has_element?(view, "#pending-permission-authority-write span", "notes")
    assert has_element?(view, "#pending-permission-authority-terminal", "Deny")
    assert has_element?(view, "#run-control-notice", "Waiting for your decision")
    refute has_element?(view, "#run-control-panel.sticky")

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="allow"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      seq: decision_seq,
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "allow",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Permission accepted. I would write notes.md now."}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    refute has_element?(view, "#pending-permission-card")
    html = render(view)
    assert html =~ "idle"
    assert html =~ "Permission audit"
    assert has_element?(view, "#run-evidence-decisions", "1")
    assert has_element?(view, "#run-permission-audit-count", "1")
    assert has_element?(view, "#permission-decision-#{decision_seq}", "Decision recorded")
    assert has_element?(view, "#permission-decision-#{decision_seq}", "allow for Write file")

    assert has_element?(
             view,
             "#permission-decision-#{decision_seq}-request",
             to_string(request_id)
           )

    assert has_element?(view, "#permission-decision-#{decision_seq}-selected", "allow")
    assert has_element?(view, "#permission-decision-#{decision_seq}-kind", "Agent permission")

    assert has_element?(
             view,
             "#permission-decision-#{decision_seq}-tool-call",
             "tool_#{request_id}"
           )

    assert has_element?(view, "#permission-decision-#{decision_seq}-actor", "local_user")
    assert has_element?(view, "#permission-decision-#{decision_seq}-outcome", "selected")

    [audit] = PermissionAudits.list_for_run(run.id)
    assert audit.request_id == request_id
    assert audit.kind == "agent_permission"
    assert audit.title == "Write file"
    assert audit.status == "resolved"
    assert audit.selected_option_id == "allow"
    assert audit.outcome == "selected"
    assert audit.actor == "local_user"
    assert audit.raw_input == %{"path" => Path.join(File.cwd!(), "notes.md")}
    assert audit.resolved_at

    assert has_element?(view, "#permission-audit-#{audit.id}-requested-at", "Requested")
    assert has_element?(view, "#permission-audit-#{audit.id}-requested-at", "UTC")
    assert has_element?(view, "#permission-audit-#{audit.id}-resolved-at", "Resolved")
    assert has_element?(view, "#permission-audit-#{audit.id}-resolved-at", "UTC")
  end

  test "denies a permission request without taking the requested action", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Deny permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "permission")

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="deny"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "deny",
                        "outcome" => "selected",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Permission denied. I will not write notes.md."}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "idle"

    [audit] = PermissionAudits.list_for_run(run.id)
    assert audit.status == "resolved"
    assert audit.selected_option_id == "deny"
    assert audit.actor == "local_user"
  end

  test "reload while waiting preserves the pending permission card", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Reload permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "permission")

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    {:ok, reloaded, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "Needs approval"
    assert html =~ "Write file"
    assert has_element?(reloaded, "#pending-permission-card")
    assert has_element?(reloaded, "#pending-permission-conversation-context", "permission")

    reloaded
    |> element(~s|#pending-permission-card button[phx-value-option-id="allow"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "allow",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    [audit] = PermissionAudits.list_for_run(run.id)
    assert audit.status == "resolved"
    assert audit.selected_option_id == "allow"
  end

  test "cancel resolves outstanding permission as cancelled", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Cancel permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "permission")

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    assert has_element?(view, "#pending-permission-cancel-button", "Cancel turn")

    view
    |> element("#pending-permission-cancel-button")
    |> render_click()

    assert_receive {:event_appended, %{type: "turn_cancelled"}}, 1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "cancelled",
                        "outcome" => "cancelled",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "idle"

    [audit] = PermissionAudits.list_for_run(run.id)
    assert audit.status == "cancelled"
    assert audit.selected_option_id == "cancelled"
    assert audit.outcome == "cancelled"
    assert audit.actor == "local_user"
  end

  test "stale permission resolution is ignored and does not reopen the request", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Stale permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "permission")

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="allow"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{type: "permission_resolved", payload: %{"request_id" => ^request_id}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    assert {:error, :not_pending} = Runs.resolve_permission(run.id, request_id, "deny")

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolution_ignored",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "deny",
                        "reason" => "not_pending",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "idle"

    resolved =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "permission_resolved"))

    assert length(resolved) == 1

    audits = PermissionAudits.list_for_run(run.id)
    assert Enum.sort(Enum.map(audits, & &1.status)) == ["ignored", "resolved"]

    ignored = Enum.find(audits, &(&1.status == "ignored"))
    assert ignored.selected_option_id == "deny"
    assert ignored.reason == "not_pending"
  end

  test "agent crash fails the in-flight turn and marks the run failed", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Crash run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "die"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_started"}}, 1_000
    assert_receive {:event_appended, %{type: "user_message", payload: %{"text" => "die"}}}, 1_000

    assert_receive {:event_appended,
                    %{type: "agent_process_exited", payload: %{"status" => status}}},
                   2_000

    assert status != 0
    assert_receive {:event_appended, %{type: "turn_failed"}}, 1_000

    assert render(view) =~ "failed"
  end

  test "agent crash resolves pending permission as system cancelled", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Crash pending permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "permission-then-die"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    assert_receive {:event_appended,
                    %{type: "agent_process_exited", payload: %{"status" => status}}},
                   2_000

    assert status != 0

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "cancelled",
                        "outcome" => "cancelled",
                        "reason" => "agent_process_exited",
                        "actor" => "system"
                      }
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_failed"}}, 1_000
    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "failed"

    [audit] = PermissionAudits.list_for_run(run.id)
    assert audit.status == "cancelled"
    assert audit.selected_option_id == "cancelled"
    assert audit.reason == "agent_process_exited"
    assert audit.actor == "system"
  end

  test "explicit restart recovers a run after an actual agent crash", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Crash restart run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "die"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "agent_process_exited"}}, 2_000
    assert_receive {:event_appended, %{type: "turn_failed"}}, 1_000

    assert render(view) =~ "failed"
    assert has_element?(view, "#run-recovery-card", "Run failed")
    assert has_element?(view, "#run-recovery-action-button", "Restart")
    assert has_element?(view, "#reconnect-run-button", "Restart")

    view
    |> element("#reconnect-run-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "failed"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    started_events =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "agent_process_started"))

    assert length(started_events) == 2
    assert render(view) =~ "connected"
    assert render(view) =~ "idle"
  end

  test "explicit restart recovers a configured fake ACP harness after crash", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-crash" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "crash",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    run = insert_run!("Fake crash restart run", "fake-crash")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, _pid} = Runs.start_run(run.id)
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "fake-crash"

    view
    |> form("#run-prompt-form", %{"prompt" => "die"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "agent_process_exited"}}, 2_000
    assert_receive {:event_appended, %{type: "turn_failed"}}, 1_000

    assert render(view) =~ "failed"
    assert has_element?(view, "#reconnect-run-button", "Restart")

    view
    |> element("#reconnect-run-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "failed"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000
    assert_receive {:run_updated, %{id: run_id, status: "idle"}}, 1_000
    assert run_id == run.id

    started_events =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "agent_process_started"))

    assert length(started_events) == 2

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "hello after restart"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Fake echo: hello after restart"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    {:ok, _reloaded, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "idle"
    assert html =~ "Fake echo: hello after restart"
  end

  test "cancel returns an open non-permission turn to idle", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Cancel open turn"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "wait"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_started"}}, 1_000
    assert_receive {:event_appended, %{type: "user_message", payload: %{"text" => "wait"}}}, 1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Waiting for cancellation."}
                    }},
                   1_000

    assert render(view) =~ "running"
    assert has_element?(view, "#send-prompt-button[disabled]")
    assert has_element?(view, ~s|#send-prompt-button[title*="turn is already in progress"]|)
    refute has_element?(view, "#cancel-run-button[title]")
    assert has_element?(view, "#run-control-notice", "A turn is already in progress")
    assert Runs.send_prompt(run.id, "second prompt") == {:error, :busy}

    view
    |> element("#cancel-run-button")
    |> render_click()

    assert_receive {:event_appended, %{type: "turn_cancelled"}}, 1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_update_ignored",
                      payload: %{
                        "reason" => "turn_cancelled",
                        "update_type" => "agent_message_chunk"
                      }
                    }},
                   1_000

    assert render(view) =~ "idle"

    refute Enum.any?(Events.list_for_run(run.id), fn
             %{type: "agent_message_chunk", payload: %{"text" => "Turn cancelled."}} -> true
             _event -> false
           end)
  end

  test "non-message session updates are preserved in the timeline", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Tool update run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "unknown-update"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "tool_call_update",
                      payload: %{
                        "sessionUpdate" => "tool_call_update",
                        "toolCallId" => "tool_unknown_1",
                        "title" => "Inspect workspace"
                      }
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    html = render(view)
    assert html =~ "tool_call_update"
    assert html =~ "Inspect workspace"
    assert has_element?(view, ~s|[data-event-kind="protocol"]|, "Protocol")
  end

  test "unknown session updates from external ACP agents are preserved without crashing", %{
    conn: conn
  } do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-usage-update" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "usage-update",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    {:ok, run} = Runs.create_run(%{"title" => "Usage update run", "agent" => "fake-usage-update"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "usage-update"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "agent_update_unknown",
                      payload: %{
                        "update_type" => "usage_update",
                        "update" => %{"size" => 258_400, "used" => 14_356}
                      }
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    html = render(view)
    assert html =~ "usage_update"

    text =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "agent_message_chunk"))
      |> Enum.map_join("", & &1.payload["text"])

    assert text == "Usage survived."
  end

  test "agent thought chunks are tracked without storing raw thought text", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-thought" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "thought",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    {:ok, run} = Runs.create_run(%{"title" => "Thought run", "agent" => "fake-thought"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "thought"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "agent_thought_redacted",
                      payload: %{
                        "redacted" => true,
                        "content_type" => "text",
                        "first_chunk_length" => 36
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{type: "agent_message_chunk", payload: %{"text" => "Thought redacted."}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    encoded_events =
      run.id
      |> Events.list_for_run()
      |> Enum.map(&{&1.type, &1.payload})
      |> inspect()

    refute encoded_events =~ "private scratchpad should not render"
    refute render(view) =~ "private scratchpad should not render"
  end

  @tag :tmp_dir
  test "handles ACP file read requests inside the run workspace", %{conn: conn, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "README.md"), "Haven capability fixture\nsecond line\n")

    {:ok, run} = Runs.create_run(%{"title" => "File read run", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "read-file")

    assert_receive {:event_appended,
                    %{type: "file_read_requested", payload: %{"path" => "README.md"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "request_id" => request_id,
                        "toolCall" => %{"title" => "Read file"}
                      }
                    }},
                   1_000

    assert has_element?(view, "#pending-permission-card", "Read file")

    assert has_element?(
             view,
             "#pending-permission-decision-action",
             "Review the requested file read."
           )

    assert has_element?(
             view,
             "#pending-permission-decision-consequence",
             "Allow sends the file contents to the agent; deny keeps them unavailable."
           )

    assert has_element?(view, "#pending-permission-request-id", to_string(request_id))
    assert has_element?(view, "#pending-permission-tool-call-id", "file_read_#{request_id}")
    assert has_element?(view, "#pending-permission-tool-status", "pending")
    assert has_element?(view, "#pending-permission-options", "Allow read (allow)")

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="allow"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "option_id" => "allow",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_read_succeeded",
                      payload: %{"path" => "README.md", "resolved_path" => resolved_path}
                    }},
                   1_000

    assert resolved_path == Path.join(tmp_dir, "README.md")

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Read file: Haven capability fixture"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    html = render(view)
    assert html =~ "file_read_succeeded"
    assert html =~ "Read file: Haven capability fixture"
  end

  @tag :tmp_dir
  test "denies ACP file read requests before returning file content", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "README.md"), "sensitive fixture\nsecond line\n")

    {:ok, run} = Runs.create_run(%{"title" => "Deny file read run", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "read-file")

    assert_receive {:event_appended,
                    %{type: "file_read_requested", payload: %{"path" => "README.md"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{"toolCall" => %{"title" => "Read file"}}
                    }},
                   1_000

    assert has_element?(view, "#pending-permission-card", "Read file")

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="deny"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "option_id" => "deny",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_read_denied",
                      payload: %{
                        "path" => "README.md",
                        "error" => %{"data" => %{"reason" => "permission_denied"}}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "File request failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    refute has_element?(view, "#pending-permission-card")

    html = render(view)
    assert html =~ "file_read_denied"
    refute html =~ "sensitive fixture"
  end

  @tag :tmp_dir
  test "auto-allows ACP file reads when the run policy grants them", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "README.md"), "policy fixture\n")

    {:ok, run} =
      Runs.create_run(%{
        "title" => "Auto allow read run",
        "workspace" => tmp_dir,
        "capability_policy" => %{"file_read" => "allow"}
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "read-file")

    assert_receive {:event_appended,
                    %{type: "file_read_requested", payload: %{"path" => "README.md"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "capability_policy_applied",
                      payload: %{
                        "capability" => "file_read",
                        "decision" => "allow"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_read_succeeded",
                      payload: %{"path" => "README.md", "resolved_path" => resolved_path}
                    }},
                   1_000

    assert resolved_path == Path.join(tmp_dir, "README.md")

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Read file: policy fixture"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute_receive {:event_appended, %{type: "permission_requested"}}, 100
    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "capability_policy_applied"
  end

  @tag :tmp_dir
  test "denies auto-allowed file reads outside configured path scopes", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "README.md"), "scoped secret\n")
    File.mkdir_p!(Path.join(tmp_dir, "docs"))

    {:ok, run} =
      Runs.create_run(%{
        "title" => "Scoped read run",
        "workspace" => tmp_dir,
        "capability_policy" => %{
          "file_read" => "allow",
          "file_read_paths" => ["docs"]
        }
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "read-file")

    assert_receive {:event_appended,
                    %{type: "file_read_requested", payload: %{"path" => "README.md"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "capability_policy_applied",
                      payload: %{
                        "capability" => "file_read",
                        "decision" => "deny",
                        "reason" => "path_scope",
                        "path_scopes" => ["docs"]
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_read_denied",
                      payload: %{
                        "path" => "README.md",
                        "error" => %{"data" => %{"reason" => "path_scope_denied"}}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "File request failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute_receive {:event_appended, %{type: "permission_requested"}}, 100
    refute has_element?(view, "#pending-permission-card")

    html = render(view)
    assert html =~ "path_scope_denied"
    refute html =~ "scoped secret"
  end

  @tag :tmp_dir
  test "handles ACP file write requests inside the run workspace", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, run} = Runs.create_run(%{"title" => "File write run", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, "#run-file-change-count", "0")
    assert has_element?(view, "#run-file-changes-empty", "No file changes recorded.")
    submit_prompt(view, "write-file")

    assert_receive {:event_appended,
                    %{
                      type: "file_write_requested",
                      payload: %{"path" => "haven-written.txt", "bytes" => bytes}
                    }},
                   1_000

    assert bytes > 0

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "toolCall" => %{
                          "title" => "Write file",
                          "rawInput" => %{
                            "content_preview" => "written by Haven ACP\n",
                            "content_truncated" => false,
                            "diff_kind" => "create",
                            "diff_preview" => diff_preview,
                            "diff_truncated" => false
                          }
                        }
                      }
                    }},
                   1_000

    assert diff_preview =~ "--- /dev/null"
    assert diff_preview =~ "+++ haven-written.txt"
    assert diff_preview =~ "+written by Haven ACP\n"
    assert has_element?(view, "#pending-permission-card", "Write file")

    assert has_element?(
             view,
             "#pending-permission-decision-action",
             "Review the proposed file change."
           )

    assert has_element?(
             view,
             "#pending-permission-decision-consequence",
             "Allow writes this content to the workspace; deny leaves files unchanged."
           )

    assert has_element?(view, "#pending-permission-proposed-file-change", "Proposed file change")
    assert has_element?(view, "#pending-permission-proposed-file-path", "haven-written.txt")
    assert has_element?(view, "#pending-permission-proposed-file-kind", "create")
    assert has_element?(view, "#pending-permission-proposed-file-change-id", "file-write-")
    assert has_element?(view, "#pending-permission-proposed-file-bytes", to_string(bytes))
    assert has_element?(view, "#pending-permission-proposed-file-existing-bytes", "0")

    assert has_element?(
             view,
             "#pending-permission-proposed-file-content",
             "written by Haven ACP"
           )

    assert has_element?(view, "#pending-permission-proposed-file-diff", "--- /dev/null")
    assert has_element?(view, "#pending-permission-proposed-file-diff", "+++ haven-written.txt")

    assert [pending_change] = FileChanges.list_for_run(run.id)
    assert pending_change.change_id
    assert pending_change.path == "haven-written.txt"
    assert pending_change.status == "pending"
    assert pending_change.diff_kind == "create"
    assert pending_change.content_preview == "written by Haven ACP\n"
    assert pending_change.diff_preview =~ "+written by Haven ACP\n"
    assert has_element?(view, "#run-file-change-count", "1")
    assert has_element?(view, "#run-file-change-review-summary")
    assert has_element?(view, "#run-file-change-pending-count", "1")
    assert has_element?(view, "#run-file-change-applied-count", "0")
    assert has_element?(view, "#run-file-change-blocked-count", "0")
    assert has_element?(view, "#file-change-#{pending_change.change_id}", "haven-written.txt")
    assert has_element?(view, "#file-change-#{pending_change.change_id}-status", "pending")

    assert has_element?(
             view,
             "#file-change-#{pending_change.change_id}-review-state",
             "Needs review"
           )

    assert has_element?(
             view,
             "#file-change-#{pending_change.change_id}-review-state",
             "before deciding"
           )

    assert has_element?(
             view,
             "#file-change-#{pending_change.change_id}-content",
             "written by Haven ACP"
           )

    assert has_element?(view, "#file-change-#{pending_change.change_id}-diff", "--- /dev/null")

    refute File.exists?(Path.join(tmp_dir, "haven-written.txt"))

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="allow"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "option_id" => "allow",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_write_succeeded",
                      payload: %{"path" => "haven-written.txt", "resolved_path" => resolved_path}
                    }},
                   1_000

    assert resolved_path == Path.join(tmp_dir, "haven-written.txt")
    assert File.read!(resolved_path) == "written by Haven ACP\n"

    assert [applied_change] = FileChanges.list_for_run(run.id)
    assert applied_change.change_id == pending_change.change_id
    assert applied_change.status == "applied"
    assert applied_change.resolved_path == resolved_path

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Wrote file through Haven."}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    html = render(view)
    assert html =~ "file_write_succeeded"
    assert html =~ "Wrote file through Haven."
    assert has_element?(view, "#run-file-change-pending-count", "0")
    assert has_element?(view, "#run-file-change-applied-count", "1")
    assert has_element?(view, "#run-file-change-blocked-count", "0")
    assert has_element?(view, "#file-change-#{applied_change.change_id}-status", "applied")
    assert has_element?(view, "#file-change-#{applied_change.change_id}-review-state", "Applied")

    assert has_element?(
             view,
             "#file-change-#{applied_change.change_id}-review-state",
             "written to the workspace"
           )

    assert has_element?(
             view,
             "#file-change-#{applied_change.change_id}-resolved-path",
             resolved_path
           )
  end

  @tag :tmp_dir
  test "bounds ACP file write previews before approval", %{tmp_dir: tmp_dir} do
    {:ok, run} = Runs.create_run(%{"title" => "Large file write run", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run.id)
    content = String.duplicate("x", 9_000)
    request = ACP.WriteTextFileRequest.new("session-large", "large.txt", content)

    task =
      Task.async(fn ->
        RunServer.agent_write_text_file_requested(pid, request)
      end)

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "request_id" => request_id,
                        "toolCall" => %{
                          "rawInput" => %{
                            "bytes" => 9_000,
                            "content_preview" => preview,
                            "content_preview_limit" => 4_000,
                            "content_truncated" => true,
                            "diff_preview" => diff_preview,
                            "diff_preview_limit" => 8_000,
                            "diff_truncated" => true
                          }
                        }
                      }
                    }},
                   1_000

    assert String.length(preview) == 4_000
    assert String.length(diff_preview) == 8_000

    assert :ok = Runs.resolve_permission(run.id, request_id, "deny")
    assert {:error, %ACP.Error{message: "Permission denied"}} = Task.await(task, 1_000)
    refute File.exists?(Path.join(tmp_dir, "large.txt"))
  end

  @tag :tmp_dir
  test "denies ACP file write requests before touching the workspace", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, run} = Runs.create_run(%{"title" => "Deny file write run", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "write-file")

    assert_receive {:event_appended,
                    %{
                      type: "file_write_requested",
                      payload: %{"path" => "haven-written.txt"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{"toolCall" => %{"title" => "Write file"}}
                    }},
                   1_000

    assert has_element?(view, "#pending-permission-card", "Write file")

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="deny"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "option_id" => "deny",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_write_denied",
                      payload: %{
                        "path" => "haven-written.txt",
                        "error" => %{"data" => %{"reason" => "permission_denied"}}
                      }
                    }},
                   1_000

    assert [denied_change] = FileChanges.list_for_run(run.id)
    assert denied_change.path == "haven-written.txt"
    assert denied_change.status == "denied"
    assert denied_change.error["data"]["reason"] == "permission_denied"

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "File request failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    refute File.exists?(Path.join(tmp_dir, "haven-written.txt"))
    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "file_write_denied"
    assert has_element?(view, "#run-file-change-pending-count", "0")
    assert has_element?(view, "#run-file-change-applied-count", "0")
    assert has_element?(view, "#run-file-change-blocked-count", "1")
    assert has_element?(view, "#file-change-#{denied_change.change_id}-status", "denied")
    assert has_element?(view, "#file-change-#{denied_change.change_id}-review-state", "Blocked")

    assert has_element?(
             view,
             "#file-change-#{denied_change.change_id}-review-state",
             "did not touch"
           )

    assert has_element?(
             view,
             "#file-change-#{denied_change.change_id}-error",
             "Permission denied"
           )
  end

  @tag :tmp_dir
  test "auto-denies ACP file writes when the run policy rejects them", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, run} =
      Runs.create_run(%{
        "title" => "Auto deny write run",
        "workspace" => tmp_dir,
        "capability_policy" => %{"file_write" => "deny"}
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "write-file")

    assert_receive {:event_appended,
                    %{
                      type: "file_write_requested",
                      payload: %{"path" => "haven-written.txt"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "capability_policy_applied",
                      payload: %{
                        "capability" => "file_write",
                        "decision" => "deny"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_write_denied",
                      payload: %{
                        "path" => "haven-written.txt",
                        "error" => %{"data" => %{"reason" => "permission_denied"}}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "File request failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute_receive {:event_appended, %{type: "permission_requested"}}, 100
    refute File.exists?(Path.join(tmp_dir, "haven-written.txt"))
    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "capability_policy_applied"
  end

  @tag :tmp_dir
  test "denies auto-allowed file writes outside configured path scopes", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, "notes"))

    {:ok, run} =
      Runs.create_run(%{
        "title" => "Scoped write run",
        "workspace" => tmp_dir,
        "capability_policy" => %{
          "file_write" => "allow",
          "file_write_paths" => ["notes"]
        }
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "write-file")

    assert_receive {:event_appended,
                    %{
                      type: "file_write_requested",
                      payload: %{"path" => "haven-written.txt"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "capability_policy_applied",
                      payload: %{
                        "capability" => "file_write",
                        "decision" => "deny",
                        "reason" => "path_scope",
                        "path_scopes" => ["notes"]
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "file_write_denied",
                      payload: %{
                        "path" => "haven-written.txt",
                        "error" => %{"data" => %{"reason" => "path_scope_denied"}}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "File request failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute_receive {:event_appended, %{type: "permission_requested"}}, 100
    refute File.exists?(Path.join(tmp_dir, "haven-written.txt"))
    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "path_scope_denied"
  end

  test "handles ACP terminal create, wait, output, and release requests visibly", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Terminal request run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "terminal")

    assert_receive {:event_appended, %{type: "terminal_create_requested"}}, 1_000

    assert_receive {:event_appended,
                    %{type: "terminal_created", payload: %{"terminal_id" => terminal_id}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_wait_requested",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_wait_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => 0}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_output_requested",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_output_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => 0}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Terminal output: hello (exit 0)"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_release_requested",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{type: "terminal_released", payload: %{"terminal_id" => ^terminal_id}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    html = render(view)
    assert html =~ "terminal_created"
    assert html =~ "terminal_output_succeeded"
    assert html =~ "Terminal output: hello"

    assert [session] = TerminalSessions.list_for_run(run.id)
    assert session.terminal_id == terminal_id
    assert session.command == "echo"
    assert session.args == %{"items" => ["hello"]}
    assert session.cwd == run.workspace
    assert session.status == "exited"
    assert session.exit_status == 0
    assert session.output_bytes == byte_size("hello\n")
    assert session.output_preview == "hello\n"
    assert session.released_at

    assert has_element?(view, "#run-terminal-session-count", "1")
    assert has_element?(view, "#run-terminal-session-summary")
    assert has_element?(view, "#run-terminal-session-running-count", "0")
    assert has_element?(view, "#run-terminal-session-completed-count", "1")
    assert has_element?(view, "#run-terminal-session-attention-count", "0")
    assert has_element?(view, "#terminal-session-#{terminal_id}", "echo")
    assert has_element?(view, "#terminal-session-#{terminal_id}-status", "exited")
    assert has_element?(view, "#terminal-session-#{terminal_id}-review-state", "Completed")

    assert has_element?(
             view,
             "#terminal-session-#{terminal_id}-review-state",
             "exited successfully"
           )

    assert has_element?(view, "#terminal-session-#{terminal_id}-args", "hello")
    assert has_element?(view, "#terminal-session-#{terminal_id}-cwd", run.workspace)
    assert has_element?(view, "#terminal-session-#{terminal_id}-exit", "0")
    assert has_element?(view, "#terminal-session-#{terminal_id}-bytes", "6")
    assert has_element?(view, "#terminal-session-#{terminal_id}-output", "hello")
  end

  test "summarizes mixed persisted terminal session outcomes", %{conn: conn} do
    run = insert_disconnected_run!("Mixed terminal sessions")

    TerminalSessions.create_session!(run.id, %{
      terminal_id: "term-running",
      command: "mix",
      args: %{"items" => ["test"]},
      cwd: run.workspace,
      env_keys: %{"items" => []},
      status: "running"
    })

    TerminalSessions.create_session!(run.id, %{
      terminal_id: "term-exited",
      command: "echo",
      args: %{"items" => ["ok"]},
      cwd: run.workspace,
      env_keys: %{"items" => []},
      status: "exited",
      exit_status: 2
    })

    TerminalSessions.create_session!(run.id, %{
      terminal_id: "term-failed",
      command: "bad",
      args: %{"items" => []},
      cwd: run.workspace,
      env_keys: %{"items" => []},
      status: "failed"
    })

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-terminal-session-count", "3")
    assert has_element?(view, "#run-terminal-session-running-count", "1")
    assert has_element?(view, "#run-terminal-session-completed-count", "1")
    assert has_element?(view, "#run-terminal-session-attention-count", "1")
    assert has_element?(view, "#terminal-session-term-running-review-state", "Running")
    assert has_element?(view, "#terminal-session-term-running-review-state", "still active")
    assert has_element?(view, "#terminal-session-term-exited-review-state", "Completed")
    assert has_element?(view, "#terminal-session-term-exited-review-state", "status 2")
    assert has_element?(view, "#terminal-session-term-failed-review-state", "Needs attention")
    assert has_element?(view, "#terminal-session-term-failed-review-state", "execution failed")
  end

  test "auto-denies ACP terminal creation when the run policy rejects it", %{conn: conn} do
    {:ok, run} =
      Runs.create_run(%{
        "title" => "Terminal denied by policy run",
        "capability_policy" => %{"terminal_create" => "deny"}
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "terminal")

    assert_receive {:event_appended,
                    %{
                      type: "terminal_create_requested",
                      payload: %{"command" => "echo"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "capability_policy_applied",
                      payload: %{
                        "capability" => "terminal_create",
                        "decision" => "deny"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_create_denied",
                      payload: %{
                        "command" => "echo",
                        "error" => %{"data" => %{"reason" => "permission_denied"}}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Terminal failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute_receive {:event_appended, %{type: "terminal_created"}}, 100

    assert TerminalSessions.list_for_run(run.id) == []

    html = render(view)
    assert html =~ "terminal_create_denied"
    assert html =~ "Terminal failed: Permission denied"
  end

  test "asks before creating an ACP terminal when the run policy requires approval", %{
    conn: conn
  } do
    {:ok, run} =
      Runs.create_run(%{
        "title" => "Terminal ask run",
        "capability_policy" => %{"terminal_create" => "ask"}
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "terminal")

    assert_receive {:event_appended,
                    %{
                      type: "terminal_create_requested",
                      payload: %{"command" => "echo"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "request_id" => request_id,
                        "toolCall" => %{
                          "title" => "Create terminal",
                          "rawInput" => %{"command" => "echo"}
                        }
                      }
                    }},
                   1_000

    assert has_element?(view, "#pending-permission-card", "Create terminal")
    assert has_element?(view, "#pending-permission-card", "Allow terminal")

    assert has_element?(
             view,
             "#pending-permission-decision-action",
             "Review the terminal command."
           )

    assert has_element?(
             view,
             "#pending-permission-decision-consequence",
             "Allow starts this process in the workspace; deny prevents it from running."
           )

    assert has_element?(view, "#pending-permission-request-id", to_string(request_id))
    assert has_element?(view, "#pending-permission-tool-call-id", "terminal_create_#{request_id}")
    assert has_element?(view, "#pending-permission-tool-status", "pending")
    assert has_element?(view, "#pending-permission-options", "Allow terminal (allow)")
    assert has_element?(view, "#pending-permission-proposed-terminal", "Proposed terminal")
    assert has_element?(view, "#pending-permission-proposed-terminal-command", "echo")
    assert has_element?(view, "#pending-permission-proposed-terminal-args", "hello")
    assert has_element?(view, "#pending-permission-proposed-terminal-cwd", run.workspace)
    assert has_element?(view, "#pending-permission-proposed-terminal-env", "none")
    refute_receive {:event_appended, %{type: "terminal_created"}}, 100

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="allow"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "allow",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{type: "terminal_created", payload: %{"terminal_id" => terminal_id}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_output_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => 0}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Terminal output: hello (exit 0)"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute has_element?(view, "#pending-permission-card")

    assert [session] = TerminalSessions.list_for_run(run.id)
    assert session.terminal_id == terminal_id
    assert session.status == "exited"
    assert session.released_at
  end

  test "denies an approval-gated ACP terminal before spawning it", %{conn: conn} do
    {:ok, run} =
      Runs.create_run(%{
        "title" => "Terminal ask denied run",
        "capability_policy" => %{"terminal_create" => "ask"}
      })

    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    submit_prompt(view, "terminal")

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "request_id" => request_id,
                        "toolCall" => %{"title" => "Create terminal"}
                      }
                    }},
                   1_000

    view
    |> element(~s|#pending-permission-card button[phx-value-option-id="deny"]|)
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "permission_resolved",
                      payload: %{
                        "request_id" => ^request_id,
                        "option_id" => "deny",
                        "actor" => "local_user"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_create_denied",
                      payload: %{
                        "command" => "echo",
                        "error" => %{"data" => %{"reason" => "permission_denied"}}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Terminal failed: Permission denied"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    refute_receive {:event_appended, %{type: "terminal_created"}}, 100
    refute has_element?(view, "#pending-permission-card")
    assert TerminalSessions.list_for_run(run.id) == []
  end

  test "handles ACP terminal kill requests visibly", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Terminal kill run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "kill-terminal"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "terminal_create_requested"}}, 1_000

    assert_receive {:event_appended,
                    %{type: "terminal_created", payload: %{"terminal_id" => terminal_id}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_kill_requested",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_kill_succeeded",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_wait_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => -1}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_output_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => -1}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Terminal killed (exit -1)."}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_released",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    assert [session] = TerminalSessions.list_for_run(run.id)
    assert session.terminal_id == terminal_id
    assert session.command == "sleep"
    assert session.status == "killed"
    assert session.exit_status == -1
    assert session.released_at

    {:ok, _reloaded, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "terminal_kill_succeeded"
    assert html =~ "Terminal killed (exit -1)."
    assert html =~ "idle"
    assert html =~ "Terminal sessions"
    assert html =~ terminal_id
    assert html =~ "killed"
  end

  test "handles ACP terminal kill requests for shell-launched children", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Terminal kill tree run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "kill-terminal-tree"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "terminal_create_requested",
                      payload: %{"command" => "sh", "args" => ["-c", "sleep 30 & wait"]}
                    }},
                   2_000

    assert_receive {:event_appended,
                    %{type: "terminal_created", payload: %{"terminal_id" => terminal_id}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_kill_succeeded",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_wait_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => -1}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_output_succeeded",
                      payload: %{"terminal_id" => ^terminal_id, "exit_status" => -1}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Terminal killed (exit -1)."}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "terminal_released",
                      payload: %{"terminal_id" => ^terminal_id}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    {:ok, _reloaded, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "terminal_kill_succeeded"
    assert html =~ "Terminal killed (exit -1)."
    assert html =~ "idle"
  end

  test "unknown agent fails visibly instead of launching the stub", %{conn: conn} do
    run = insert_run!("Unknown agent run", "missing-agent")
    Events.subscribe(run.id)

    {:ok, _pid} = Runs.start_run(run.id)

    assert_receive {:event_appended,
                    %{
                      seq: seq,
                      type: "agent_start_failed",
                      payload: %{"reason" => reason}
                    }},
                   1_000

    assert reason =~ "unknown_agent"

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "failed"
    assert has_element?(view, "#runtime-failure-#{seq}", "Agent start failed")
    assert has_element?(view, "#runtime-failure-#{seq}-reason", "unknown_agent")
    assert has_element?(view, "#runtime-failure-#{seq}-agent", "missing-agent")
  end

  test "malformed ACP startup output fails visibly without restarting", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "malformed-agent" => %{
        executable: System.find_executable("mix"),
        args: ["run", "--no-compile", "--no-start", "priv/malformed_agent.exs"]
      }
    })

    run = insert_run!("Malformed agent run", "malformed-agent")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, _pid} = Runs.start_run(run.id)

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000

    assert_receive {:event_appended,
                    %{
                      seq: seq,
                      type: "agent_protocol_failed",
                      payload: %{"reason" => reason}
                    }},
                   1_000

    assert reason =~ "protocol_exit"

    assert_receive {:run_updated, %{id: run_id, status: "failed"}}, 1_000
    assert run_id == run.id
    assert Runs.get_run!(run.id).status == "failed"

    started_events =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "agent_process_started"))

    assert length(started_events) == 1

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "failed"
    assert has_element?(view, "#runtime-failure-#{seq}", "Agent protocol failed")
    assert has_element?(view, "#runtime-failure-#{seq}-reason", "protocol_exit")
    assert has_element?(view, "#runtime-failure-#{seq}-agent", "malformed-agent")
  end

  test "malformed ACP output after session start fails the active run", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Malformed after start run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "malformed-after-start"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_started"}}, 1_000

    assert_receive {:event_appended,
                    %{type: "user_message", payload: %{"text" => "malformed-after-start"}}},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_protocol_failed",
                      payload: %{
                        "reason" => "malformed_agent_output",
                        "line" => "this is not json"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "turn_failed",
                      payload: %{
                        "request_id" => 1,
                        "error" => "malformed_agent_output"
                      }
                    }},
                   1_000

    assert_receive {:run_updated, %{id: run_id, status: "failed"}}, 1_000
    assert run_id == run.id

    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run.id)
    _ = :sys.get_state(pid)

    refute Enum.any?(Events.list_for_run(run.id), &(&1.type == "agent_process_down"))

    assert render(view) =~ "failed"
    assert render(view) =~ "agent_protocol_failed"
    assert render(view) =~ "malformed_agent_output"
  end

  test "configured fake ACP harness malformed output fails the active run", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-malformed" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "malformed",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    run = insert_run!("Fake malformed run", "fake-malformed")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, _pid} = Runs.start_run(run.id)
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "fake-malformed"

    view
    |> form("#run-prompt-form", %{"prompt" => "malformed-after-start"})
    |> render_submit()

    assert_receive {:event_appended, %{type: "turn_started"}}, 1_000

    assert_receive {:event_appended,
                    %{
                      type: "agent_protocol_failed",
                      payload: %{
                        "reason" => "malformed_agent_output",
                        "line" => "fake malformed frame"
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "turn_failed",
                      payload: %{"error" => "malformed_agent_output"}
                    }},
                   1_000

    assert_receive {:run_updated, %{id: run_id, status: "failed"}}, 1_000
    assert run_id == run.id

    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run.id)
    _ = :sys.get_state(pid)

    assert Runs.get_run!(run.id).status == "failed"
    refute Enum.any?(Events.list_for_run(run.id), &(&1.type == "agent_process_down"))

    {:ok, _reloaded, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "failed"
    assert html =~ "fake malformed frame"
  end

  test "configured agent key drives the launched ACP process", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "configured-stub" => %{
        executable: System.find_executable("mix"),
        args: ["run", "--no-compile", "--no-start", "priv/agent_stub.exs", "{workspace}"],
        cwd: "{workspace}",
        env: [{"HAVEN_AGENT_ENV_SMOKE", "configured-secret"}]
      }
    })

    run = insert_run!("Configured agent run", "configured-stub")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    {:ok, _pid} = Runs.start_run(run.id)

    assert_receive {:event_appended,
                    %{
                      type: "agent_process_started",
                      payload: %{
                        "agent" => "configured-stub",
                        "command" => "configured-stub",
                        "args" => args,
                        "cwd" => cwd,
                        "env" => env
                      }
                    }},
                   1_000

    assert List.last(args) == run.workspace
    assert cwd == run.workspace
    assert env == ["HAVEN_AGENT_ENV_SMOKE"]
    refute inspect(Events.list_for_run(run.id)) =~ "configured-secret"
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "configured-stub"
    assert html =~ "agent_session_started"

    view
    |> form("#run-prompt-form", %{"prompt" => "env"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Env: configured-secret"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run.id)
    _ = :sys.get_state(pid)
  end

  test "configured fake ACP harness streams partial chunks durably", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-streaming" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "streaming",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    run = insert_run!("Fake streaming run", "fake-streaming")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, _pid} = Runs.start_run(run.id)
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "fake-streaming"

    view
    |> form("#run-prompt-form", %{"prompt" => "partial-stream"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{type: "agent_message_chunk", payload: %{"text" => "Partial "}}},
                   1_000

    assert_receive {:event_appended,
                    %{type: "agent_message_chunk", payload: %{"text" => "streamed "}}},
                   1_000

    assert_receive {:event_appended,
                    %{type: "agent_message_chunk", payload: %{"text" => "answer."}}},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    assert_receive {:run_updated, %{id: run_id, status: "idle"}}, 1_000
    assert run_id == run.id

    agent_chunk_events =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "agent_message_chunk"))

    streamed_text = Enum.map(agent_chunk_events, & &1.payload["text"])
    assert streamed_text == ["Partial ", "streamed ", "answer."]
    [first_chunk, second_chunk, third_chunk] = agent_chunk_events

    {:ok, reloaded, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(reloaded, "#haven-run", "idle")
    assert has_element?(reloaded, "#run-conversation")

    assert has_element?(
             reloaded,
             ~s|#run-conversation [data-conversation-role="user"]|,
             "partial-stream"
           )

    assert has_element?(
             reloaded,
             ~s|#run-conversation [data-conversation-role="agent"]|,
             "Partial streamed answer."
           )

    assert has_element?(
             reloaded,
             "#conversation-message-#{first_chunk.seq}",
             "Partial streamed answer."
           )

    refute has_element?(reloaded, "#conversation-message-#{second_chunk.seq}")
    refute has_element?(reloaded, "#conversation-message-#{third_chunk.seq}")
  end

  test "configured fake ACP harness cancels duplicate permission requests", %{conn: conn} do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-duplicate-permission" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "duplicate-permission",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    run = insert_run!("Fake duplicate permission run", "fake-duplicate-permission")
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)
    Runs.subscribe()

    {:ok, _pid} = Runs.start_run(run.id)
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> form("#run-prompt-form", %{"prompt" => "duplicate-permission"})
    |> render_submit()

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "request_id" => first_request_id,
                        "toolCall" => %{"title" => "First permission"}
                      }
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{
                        "request_id" => second_request_id,
                        "toolCall" => %{"title" => "Second permission"}
                      }
                    }},
                   1_000

    assert first_request_id != second_request_id

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, "#pending-permission-card")

    view
    |> element("#cancel-run-button")
    |> render_click()

    assert_receive {:event_appended, %{type: "turn_cancelled"}}, 1_000

    resolved_ids =
      for _ <- 1..2 do
        assert_receive {:event_appended,
                        %{
                          type: "permission_resolved",
                          payload: %{
                            "option_id" => "cancelled",
                            "outcome" => "cancelled",
                            "actor" => "local_user"
                          }
                        } = event},
                       1_000

        event.payload["request_id"]
      end

    assert MapSet.new(resolved_ids) == MapSet.new([first_request_id, second_request_id])

    assert_receive {:event_appended,
                    %{
                      type: "agent_update_ignored",
                      payload: %{
                        "reason" => "turn_cancelled",
                        "update_type" => "agent_message_chunk"
                      }
                    }},
                   1_000

    assert_receive {:run_updated, %{id: run_id, status: "idle"}}, 1_000
    assert run_id == run.id

    refute has_element?(view, "#pending-permission-card")

    events = Events.list_for_run(run.id)

    assert 2 ==
             Enum.count(events, fn
               %{type: "permission_resolved", payload: %{"outcome" => "cancelled"}} -> true
               _event -> false
             end)

    refute Enum.any?(events, fn
             %{
               type: "agent_message_chunk",
               payload: %{"text" => "Duplicate permissions resolved."}
             } ->
               true

             _event ->
               false
           end)
  end

  defp sync_run_server!(run_id) do
    {:ok, pid} = Runs.ensure_started(run_id)
    _ = :sys.get_state(pid)
    :ok
  end

  defp wait_for_event!(run_id, type, attempts \\ 40)

  defp wait_for_event!(run_id, type, 0) do
    flunk("run #{run_id} did not append #{type}")
  end

  defp wait_for_event!(run_id, type, attempts) do
    if Enum.any?(Events.list_for_run(run_id), &(&1.type == type)) do
      :ok
    else
      receive do
      after
        50 -> wait_for_event!(run_id, type, attempts - 1)
      end
    end
  end

  defp wait_for_idle_session!(run_id, attempts \\ 40)

  defp wait_for_idle_session!(run_id, 0) do
    flunk("run #{run_id} did not reach idle session")
  end

  defp wait_for_idle_session!(run_id, attempts) do
    sync_run_server!(run_id)
    run = Runs.get_run!(run_id)

    if run.status == "idle" and is_binary(run.agent_session_id) do
      :ok
    else
      receive do
      after
        50 -> wait_for_idle_session!(run_id, attempts - 1)
      end
    end
  end

  defp stop_run_server_on_exit(run_id) do
    on_exit(fn ->
      Runs.stop_run(run_id)
    end)
  end

  defp collect_repo_queries(acc \\ []) do
    receive do
      {:repo_query, metadata} -> collect_repo_queries([metadata | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp insert_run!(title, agent) do
    run =
      %Run{}
      |> Run.changeset(%{
        title: title,
        workspace: File.cwd!(),
        agent: agent,
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

  defp insert_disconnected_run!(title, status \\ "idle") do
    run =
      %Run{}
      |> Run.changeset(%{
        title: title,
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: status,
        agent_session_id: "old-session"
      })
      |> Repo.insert!()

    Events.append!(run.id, "run_created", %{
      "title" => run.title,
      "workspace" => run.workspace,
      "agent" => run.agent
    })

    Events.append!(run.id, "agent_session_started", %{
      "agent_session_id" => run.agent_session_id
    })

    run
  end

  defp append_permission_requested!(run_id, request_id) do
    payload = %{
      "request_id" => request_id,
      "toolCall" => %{
        "id" => "tool-#{request_id}",
        "title" => "Write file",
        "rawInput" => %{"path" => "notes.md"},
        "status" => "pending"
      },
      "options" => [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]
    }

    Events.append!(run_id, "permission_requested", payload)
    PermissionAudits.create_pending!(run_id, :agent_permission, payload)
  end
end
