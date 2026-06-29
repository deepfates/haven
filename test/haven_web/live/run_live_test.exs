defmodule HavenWeb.RunLiveTest do
  use HavenWeb.ConnCase

  alias Haven.Events
  alias Haven.Repo
  alias Haven.Runs
  alias Haven.Runs.{Run, RunServer}

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
    assert has_element?(view, "#run-policy-file-read-paths", "README.md, docs")
    assert has_element?(view, "#run-policy-file-write", "Ask")
    assert has_element?(view, "#run-policy-file-write-paths", "notes")
    assert has_element?(view, "#run-policy-terminal-create", "Deny")
  end

  test "viewing disconnected idle history does not spawn a new agent process", %{conn: conn} do
    run = insert_disconnected_run!("Disconnected history")

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "Disconnected history"
    assert html =~ "not connected"
    assert has_element?(view, "#send-prompt-button[disabled]")
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

    assert has_element?(view, "#reconnect-run-button", "Reconnect")

    view
    |> element("#reconnect-run-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{
                      type: "run_reconnect_requested",
                      payload: %{"previous_status" => "idle"}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

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

    assert html =~ "not connected"
    assert has_element?(view, "#pending-permission-card", "Write file")
    assert has_element?(view, ~s|#pending-permission-card button[disabled]|)
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

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "connected"
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

    assert_receive {:event_appended, %{type: "agent_process_started"}}, 1_000
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

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

    assert render(view) =~ "connected"
  end

  test "sends a prompt and appends user and agent turn events", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Prompt run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

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
    refute render(view) =~ "Echo: hello from filter test"
    refute has_element?(view, ~s|[data-event-kind="agent"]|)

    view
    |> element("#timeline-filter-all")
    |> render_click()

    assert has_element?(view, ~s|[data-event-kind="runtime"]|, "Runtime")
    assert has_element?(view, ~s|[data-event-kind="agent"]|, "Agent")
    assert has_element?(view, ~s|[data-event-kind="user"]|, "User")
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
    {:ok, run} = Runs.create_run(%{"title" => "Permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> element("#sample-permission-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    html = render(view)
    assert html =~ "Needs approval"
    assert html =~ "Write file"
    assert has_element?(view, "#pending-permission-card")

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
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Permission accepted. I would write notes.md now."}
                    }},
                   1_000

    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    refute has_element?(view, "#pending-permission-card")
    assert render(view) =~ "idle"
  end

  test "denies a permission request without taking the requested action", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Deny permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> element("#sample-permission-button")
    |> render_click()

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
  end

  test "reload while waiting preserves the pending permission card", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Reload permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> element("#sample-permission-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    {:ok, reloaded, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "Needs approval"
    assert html =~ "Write file"
    assert has_element?(reloaded, "#pending-permission-card")

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
  end

  test "cancel resolves outstanding permission as cancelled", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Cancel permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> element("#sample-permission-button")
    |> render_click()

    assert_receive {:event_appended,
                    %{type: "permission_requested", payload: %{"request_id" => request_id}}},
                   1_000

    view
    |> element("#cancel-run-button")
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
  end

  test "stale permission resolution is ignored and does not reopen the request", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{"title" => "Stale permission run"})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> element("#sample-permission-button")
    |> render_click()

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
    assert has_element?(view, "#sample-echo-button[disabled]")
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

  @tag :tmp_dir
  test "handles ACP file read requests inside the run workspace", %{conn: conn, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "README.md"), "Haven capability fixture\nsecond line\n")

    {:ok, run} = Runs.create_run(%{"title" => "File read run", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view
    |> element("#sample-read-file-button")
    |> render_click()

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

    view
    |> element("#sample-read-file-button")
    |> render_click()

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

    view
    |> element("#sample-read-file-button")
    |> render_click()

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

    view
    |> element("#sample-read-file-button")
    |> render_click()

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

    view
    |> element("#sample-write-file-button")
    |> render_click()

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
    assert has_element?(view, "#pending-permission-card", "written by Haven ACP")
    assert has_element?(view, "#pending-permission-card", "diff_preview")

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

    view
    |> element("#sample-write-file-button")
    |> render_click()

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

    view
    |> element("#sample-write-file-button")
    |> render_click()

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

    view
    |> element("#sample-write-file-button")
    |> render_click()

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

    view
    |> element("#sample-terminal-button")
    |> render_click()

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

    view
    |> element("#sample-terminal-button")
    |> render_click()

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

    view
    |> element("#sample-terminal-button")
    |> render_click()

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

    view
    |> element("#sample-terminal-button")
    |> render_click()

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

    {:ok, _reloaded, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "terminal_kill_succeeded"
    assert html =~ "Terminal killed (exit -1)."
    assert html =~ "idle"
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
                   1_000

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
                      type: "agent_start_failed",
                      payload: %{"reason" => reason}
                    }},
                   1_000

    assert reason =~ "unknown_agent"

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "failed"
    assert html =~ "agent_start_failed"
    assert html =~ "missing-agent"
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

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "failed"
    assert html =~ "agent_protocol_failed"
    assert html =~ "malformed-agent"
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

    streamed_text =
      run.id
      |> Events.list_for_run()
      |> Enum.filter(&(&1.type == "agent_message_chunk"))
      |> Enum.map(& &1.payload["text"])

    assert streamed_text == ["Partial ", "streamed ", "answer."]

    {:ok, _reloaded, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "idle"
    assert html =~ "answer."
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
    Events.append!(run_id, "permission_requested", %{
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
    })
  end
end
