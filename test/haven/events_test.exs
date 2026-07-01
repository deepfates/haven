defmodule Haven.EventsTest do
  use Haven.DataCase

  alias Haven.Events
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
end
