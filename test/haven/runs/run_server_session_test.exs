defmodule Haven.Runs.RunServerSessionTest do
  @moduledoc """
  Exercises ACP session/load (resume) and session/set_mode against the fake
  agent harness ("resume" scenario advertises the loadSession capability and
  session modes) and against the built-in stub (which advertises neither, so
  the capability-gated rejection paths must be recorded loudly as events).
  """

  use Haven.DataCase

  alias Haven.Events
  alias Haven.FakeACPAgent
  alias Haven.Runs

  @agent_event_timeout 5_000

  setup do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)

    Application.put_env(:haven, :agents, %{
      "fake-resume" => %{
        executable: System.find_executable("mix"),
        args: [
          "run",
          "--no-compile",
          "--no-start",
          "test/support/fake_agent_runner.exs",
          "resume",
          "{workspace}"
        ],
        cwd: "{workspace}",
        env: [{"MIX_ENV", "test"}]
      }
    })

    :ok
  end

  test "reconnect resumes the agent session via session/load and folds replayed history" do
    {:ok, run} = Runs.create_run(%{"title" => "Resume run", "agent" => "fake-resume"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    wait_for_idle_session!(run.id)
    run = Runs.get_run!(run.id)
    session_id = run.agent_session_id
    clean_session_store_on_exit(session_id)

    assert %{payload: %{"load_session_supported" => true}} =
             find_event(run.id, "agent_initialized")

    assert :ok = Runs.send_prompt(run.id, "hello resume")

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Fake echo: hello resume"}
                    }},
                   @agent_event_timeout

    assert_receive {:event_appended, %{type: "turn_finished"}}, @agent_event_timeout

    :ok = Runs.stop_run(run.id)
    assert {:ok, _pid} = Runs.reconnect_run(run.id)

    assert_receive {:event_appended, %{type: "agent_session_loaded", payload: payload}},
                   @agent_event_timeout

    assert payload["agent_session_id"] == session_id
    assert %{"currentModeId" => "default"} = payload["modes"]

    # The agent replayed the prior exchange (user chunk + agent chunk), but
    # both were already in the ledger, so they fold instead of duplicating.
    assert_receive {:event_appended, %{type: "session_replay_settled", payload: settled_payload}},
                   @agent_event_timeout

    assert settled_payload["agent_session_id"] == session_id
    assert settled_payload["folded_total"] == 2
    assert settled_payload["replayed_new"] == 0

    run = Runs.get_run!(run.id)
    assert run.status == "idle"
    assert run.agent_session_id == session_id

    refute find_event(run.id, "session_load_skipped")
    refute find_event(run.id, "session_load_failed")
    assert [_only_new_session] = find_events(run.id, "agent_session_started")

    assert :ok = Runs.send_prompt(run.id, "after resume")

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Fake echo: after resume"}
                    }},
                   @agent_event_timeout

    assert_receive {:event_appended, %{type: "turn_finished"}}, @agent_event_timeout
  end

  test "resumed-run ledger shows history once and lands genuinely-new replayed events" do
    {:ok, run} = Runs.create_run(%{"title" => "Dedupe run", "agent" => "fake-resume"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    wait_for_idle_session!(run.id)
    run = Runs.get_run!(run.id)
    session_id = run.agent_session_id
    clean_session_store_on_exit(session_id)

    assert :ok = Runs.send_prompt(run.id, "hello resume")
    assert_receive {:event_appended, %{type: "turn_finished"}}, @agent_event_timeout

    :ok = Runs.stop_run(run.id)

    # Simulate agent-side history Haven never saw (a turn that happened while
    # detached): the resume replay now carries one genuinely-new agent chunk
    # on top of the overlapping history.
    add_offline_agent_note!(session_id, "offline note")

    assert {:ok, _pid} = Runs.reconnect_run(run.id)

    assert_receive {:event_appended, %{type: "session_replay_settled", payload: settled_payload}},
                   @agent_event_timeout

    # Overlapping history folded (user chunk + agent chunk)...
    assert settled_payload["folded_total"] == 2

    assert settled_payload["folded"] == %{
             "user_message_chunk" => 1,
             "agent_message_chunk" => 1
           }

    # ...while the genuinely-new replayed chunk landed, marked as replay.
    assert settled_payload["replayed_new"] == 1

    assert [%{payload: offline_payload}] =
             events_with_text(run.id, "agent_message_chunk", "offline note")

    assert offline_payload["replay"] == true

    # The ledger shows the original exchange exactly once.
    assert [original_chunk] =
             events_with_text(run.id, "agent_message_chunk", "Fake echo: hello resume")

    refute original_chunk.payload["replay"]
    assert [_original_prompt] = events_with_text(run.id, "user_message", "hello resume")
    assert [] = find_events(run.id, "user_message_chunk")

    # A second resume must not re-land the replay-marked offline note either:
    # the fold identity strips the replay marker, so it folds this time.
    :ok = Runs.stop_run(run.id)
    assert {:ok, _pid} = Runs.reconnect_run(run.id)

    assert_receive {:event_appended, %{type: "session_replay_settled", payload: second_settled}},
                   @agent_event_timeout

    assert second_settled["folded_total"] == 3
    assert second_settled["replayed_new"] == 0

    assert [_still_one] =
             events_with_text(run.id, "agent_message_chunk", "Fake echo: hello resume")

    assert [_still_one_note] = events_with_text(run.id, "agent_message_chunk", "offline note")
    assert [_still_one_prompt] = events_with_text(run.id, "user_message", "hello resume")

    # The resumed session still accepts genuinely-new live turns.
    run = Runs.get_run!(run.id)
    assert run.status == "idle"
    assert :ok = Runs.send_prompt(run.id, "after dedupe")

    assert_receive {:event_appended,
                    %{
                      type: "agent_message_chunk",
                      payload: %{"text" => "Fake echo: after dedupe"}
                    }},
                   @agent_event_timeout

    assert_receive {:event_appended, %{type: "turn_finished"}}, @agent_event_timeout
  end

  test "set_session_mode switches the advertised permission mode and survives resume" do
    {:ok, run} = Runs.create_run(%{"title" => "Mode run", "agent" => "fake-resume"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    wait_for_idle_session!(run.id)
    run = Runs.get_run!(run.id)
    session_id = run.agent_session_id
    clean_session_store_on_exit(session_id)

    assert %{payload: %{"modes" => %{"currentModeId" => "default"}}} =
             find_event(run.id, "agent_session_started")

    assert {:error, :unknown_mode} = Runs.set_session_mode(run.id, "bogus")

    assert_receive {:event_appended,
                    %{
                      type: "session_mode_rejected",
                      payload: %{"mode_id" => "bogus", "reason" => "unknown_mode"}
                    }},
                   @agent_event_timeout

    assert :ok = Runs.set_session_mode(run.id, "plan")

    assert_receive {:event_appended,
                    %{
                      type: "session_mode_changed",
                      payload: %{"agent_session_id" => ^session_id, "mode_id" => "plan"}
                    }},
                   @agent_event_timeout

    assert_receive {:event_appended,
                    %{
                      type: "current_mode_update",
                      payload: %{"currentModeId" => "plan"}
                    }},
                   @agent_event_timeout

    :ok = Runs.stop_run(run.id)
    assert {:ok, _pid} = Runs.reconnect_run(run.id)

    assert_receive {:event_appended, %{type: "agent_session_loaded", payload: payload}},
                   @agent_event_timeout

    assert payload["agent_session_id"] == session_id
    assert %{"currentModeId" => "plan"} = payload["modes"]
  end

  test "agents without loadSession or modes get recorded skips instead of silent drops" do
    {:ok, run} = Runs.create_run(%{"title" => "Gated run"})
    stop_run_server_on_exit(run.id)
    Events.subscribe(run.id)

    wait_for_idle_session!(run.id)
    run = Runs.get_run!(run.id)
    first_session_id = run.agent_session_id

    assert %{payload: %{"load_session_supported" => false}} =
             find_event(run.id, "agent_initialized")

    assert {:error, :modes_not_advertised} = Runs.set_session_mode(run.id, "plan")

    assert_receive {:event_appended,
                    %{
                      type: "session_mode_rejected",
                      payload: %{"mode_id" => "plan", "reason" => "modes_not_advertised"}
                    }},
                   @agent_event_timeout

    :ok = Runs.stop_run(run.id)
    assert {:ok, _pid} = Runs.reconnect_run(run.id)

    assert_receive {:event_appended,
                    %{
                      type: "session_load_skipped",
                      payload: %{
                        "agent_session_id" => ^first_session_id,
                        "reason" => "load_session_capability_not_advertised"
                      }
                    }},
                   @agent_event_timeout

    # A fresh session/new ran (one start per boot), never session/load.
    second_started =
      wait_until!(fn ->
        case find_events(run.id, "agent_session_started") do
          [_first, second] -> second
          _events -> nil
        end
      end)

    refute find_event(run.id, "agent_session_loaded")

    wait_until!(fn ->
      run = Runs.get_run!(run.id)

      run.status == "idle" and
        run.agent_session_id == second_started.payload["agent_session_id"]
    end)
  end

  defp find_event(run_id, type) do
    run_id |> Events.list_for_run() |> Enum.find(&(&1.type == type))
  end

  defp events_with_text(run_id, type, text) do
    run_id
    |> find_events(type)
    |> Enum.filter(&(&1.payload["text"] == text))
  end

  defp add_offline_agent_note!(session_id, text) do
    path = FakeACPAgent.session_store_path(session_id)
    store = path |> File.read!() |> Jason.decode!()

    history = Map.get(store, "history", []) ++ [%{"role" => "agent", "text" => text}]

    File.write!(path, Jason.encode!(Map.put(store, "history", history)))
  end

  defp find_events(run_id, type) do
    run_id |> Events.list_for_run() |> Enum.filter(&(&1.type == type))
  end

  defp wait_until!(fun, attempts \\ 100)

  defp wait_until!(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until!(fun, attempts) do
    case fun.() do
      result when result in [nil, false] ->
        Process.sleep(50)
        wait_until!(fun, attempts - 1)

      result ->
        result
    end
  end

  defp wait_for_idle_session!(run_id, attempts \\ 100)

  defp wait_for_idle_session!(run_id, 0) do
    flunk("run #{run_id} did not reach an idle session")
  end

  defp wait_for_idle_session!(run_id, attempts) do
    run = Runs.get_run!(run_id)

    if run.status == "idle" and is_binary(run.agent_session_id) do
      :ok
    else
      Process.sleep(50)
      wait_for_idle_session!(run_id, attempts - 1)
    end
  end

  defp stop_run_server_on_exit(run_id) do
    on_exit(fn -> Runs.stop_run(run_id) end)
  end

  defp clean_session_store_on_exit(session_id) do
    on_exit(fn -> File.rm(FakeACPAgent.session_store_path(session_id)) end)
  end
end
