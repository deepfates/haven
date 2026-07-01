defmodule Haven.EventsTest do
  use Haven.DataCase

  alias Haven.Events
  alias Haven.Events.Event
  alias Haven.Repo
  alias Haven.Runs.Run

  test "events are append-only and sequenced per run" do
    run =
      %Run{}
      |> Run.changeset(%{
        title: "Test run",
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: "idle"
      })
      |> Repo.insert!()

    Events.append!(run.id, "run_created", %{"title" => run.title})
    Events.append!(run.id, "user_message", %{"text" => "hello"})

    assert [
             %{seq: 1, type: "run_created"},
             %{seq: 2, type: "user_message", payload: %{"text" => "hello"}}
           ] = Events.list_for_run(run.id)
  end

  test "append normalizes nested payload keys before storage and broadcast" do
    run =
      %Run{}
      |> Run.changeset(%{
        title: "Normalized payload run",
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: "idle"
      })
      |> Repo.insert!()

    Events.subscribe(run.id)

    event =
      Events.append!(run.id, "capability_policy_applied", %{
        capability: "file_read",
        decision: "deny",
        nested: %{reason: "path_scope"},
        scopes: [%{path: "README.md"}]
      })

    assert event.payload == %{
             "capability" => "file_read",
             "decision" => "deny",
             "nested" => %{"reason" => "path_scope"},
             "scopes" => [%{"path" => "README.md"}]
           }

    assert_receive {:event_appended, broadcast_event}
    assert broadcast_event.payload == event.payload

    assert [%{payload: stored_payload}] = Events.list_for_run(run.id)
    assert stored_payload == event.payload
  end

  test "changeset rejects non-json-compatible payload values" do
    changeset =
      Event.changeset(%Event{}, %{
        run_id: Ecto.UUID.generate(),
        seq: 1,
        type: "invalid_payload",
        payload: %{"bad" => {:tuple, "value"}}
      })

    refute changeset.valid?
    assert {"must contain only JSON-compatible values", _meta} = changeset.errors[:payload]
  end

  test "changeset trims event type and rejects blank types" do
    trimmed =
      Event.changeset(%Event{}, %{
        run_id: Ecto.UUID.generate(),
        seq: 1,
        type: " run_created ",
        payload: %{}
      })

    assert trimmed.valid?
    assert Ecto.Changeset.get_change(trimmed, :type) == "run_created"

    blank =
      Event.changeset(%Event{}, %{
        run_id: Ecto.UUID.generate(),
        seq: 1,
        type: "   ",
        payload: %{}
      })

    refute blank.valid?
    assert {"can't be blank", _meta} = blank.errors[:type]
  end

  test "append rejects non-json-compatible payload values before storage" do
    run = insert_run!("Invalid payload run")

    assert_raise Ecto.InvalidChangesetError, ~r/must contain only JSON-compatible values/, fn ->
      Events.append!(run.id, "invalid_payload", %{bad: self()})
    end

    assert Events.list_for_run(run.id) == []
  end

  test "append rejects blank event types before storage" do
    run = insert_run!("Blank event type run")

    error =
      assert_raise Ecto.InvalidChangesetError, fn ->
        Events.append!(run.id, "   ", %{})
      end

    assert %{type: ["can't be blank"]} = errors_on(error.changeset)

    assert Events.list_for_run(run.id) == []
  end

  test "concurrent appends preserve contiguous per-run sequence numbers" do
    run = insert_run!("Concurrent event run")

    appended =
      1..25
      |> Task.async_stream(
        fn index ->
          Events.append!(run.id, "agent_message_chunk", %{index: index})
        end,
        max_concurrency: 25,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, event} -> event end)

    assert length(appended) == 25

    events = Events.list_for_run(run.id)

    assert Enum.map(events, & &1.seq) == Enum.to_list(1..25)
    assert events |> Enum.map(& &1.payload["index"]) |> Enum.sort() == Enum.to_list(1..25)
  end

  test "latest_by_run_id returns only the newest event for each requested run" do
    alpha = insert_run!("Alpha")
    beta = insert_run!("Beta")
    missing = Ecto.UUID.generate()

    Events.append!(alpha.id, "run_created", %{"title" => "Alpha"})
    alpha_latest = Events.append!(alpha.id, "agent_message_chunk", %{"text" => "latest alpha"})
    Events.append!(beta.id, "run_created", %{"title" => "Beta"})
    beta_latest = Events.append!(beta.id, "turn_finished", %{"result" => "done"})

    latest = Events.latest_by_run_id([alpha.id, beta.id, alpha.id, missing])

    assert Map.keys(latest) |> Enum.sort() == Enum.sort([alpha.id, beta.id])
    assert latest[alpha.id].id == alpha_latest.id
    assert latest[alpha.id].payload["text"] == "latest alpha"
    assert latest[beta.id].id == beta_latest.id
    assert latest[beta.id].type == "turn_finished"
  end

  test "latest_by_run_id handles an empty run list" do
    assert Events.latest_by_run_id([]) == %{}
  end

  defp insert_run!(title) do
    %Run{}
    |> Run.changeset(%{
      title: title,
      workspace: File.cwd!(),
      agent: "stub-acp",
      status: "idle"
    })
    |> Repo.insert!()
  end
end
