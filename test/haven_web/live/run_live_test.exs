defmodule HavenWeb.RunLiveTest do
  use HavenWeb.ConnCase

  alias Haven.Events
  alias Haven.Runs

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

  defp sync_run_server!(run_id) do
    {:ok, pid} = Runs.ensure_started(run_id)
    _ = :sys.get_state(pid)
    :ok
  end

  defp stop_run_server_on_exit(run_id) do
    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Haven.Runs.Registry, run_id) do
        DynamicSupervisor.terminate_child(Haven.Runs.Supervisor, pid)
      end
    end)
  end
end
