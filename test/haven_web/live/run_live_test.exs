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

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "run_created"
    assert html =~ "agent_process_started"
    assert html =~ "agent_initialized"
    assert html =~ "agent_session_started"

    {:ok, _reloaded, reloaded_html} = live(conn, ~p"/runs/#{run.id}")

    assert reloaded_html =~ "Durable run"
    assert reloaded_html =~ "agent_session_started"
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
                      payload: %{"request_id" => ^request_id, "option_id" => "allow"}
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
                        "outcome" => "selected"
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
                      payload: %{"request_id" => ^request_id, "option_id" => "allow"}
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
                        "outcome" => "cancelled"
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
                        "reason" => "not_pending"
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
end
