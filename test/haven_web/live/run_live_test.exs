defmodule HavenWeb.RunLiveTest do
  use HavenWeb.ConnCase

  alias Haven.Events
  alias Haven.Repo
  alias Haven.Runs
  alias Haven.Runs.Run

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

    assert has_element?(view, "#pending-permission-card")

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
    assert render(view) =~ "idle"
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
                      payload: %{"toolCall" => %{"title" => "Write file"}}
                    }},
                   1_000

    assert has_element?(view, "#pending-permission-card", "Write file")

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
        args: ["run", "--no-compile", "--no-start", "priv/agent_stub.exs", "{workspace}"]
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
                        "args" => args
                      }
                    }},
                   1_000

    assert List.last(args) == run.workspace
    assert_receive {:event_appended, %{type: "agent_session_started"}}, 1_000

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "configured-stub"
    assert html =~ "agent_session_started"
  end

  defp sync_run_server!(run_id) do
    {:ok, pid} = Runs.ensure_started(run_id)
    _ = :sys.get_state(pid)
    :ok
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
end
