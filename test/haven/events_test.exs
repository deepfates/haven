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
end
