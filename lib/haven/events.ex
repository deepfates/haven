defmodule Haven.Events do
  import Ecto.Query

  alias Haven.Events.Event
  alias Haven.Repo

  def append!(run_id, type, payload \\ %{}) do
    seq =
      Repo.one(
        from e in Event,
          where: e.run_id == ^run_id,
          select: coalesce(max(e.seq), 0)
      ) + 1

    %Event{}
    |> Event.changeset(%{run_id: run_id, seq: seq, type: type, payload: payload})
    |> Repo.insert!()
    |> tap(&broadcast(run_id, {:event_appended, &1}))
  end

  def list_for_run(run_id) do
    Repo.all(from e in Event, where: e.run_id == ^run_id, order_by: [asc: e.seq])
  end

  def subscribe(run_id), do: Phoenix.PubSub.subscribe(Haven.PubSub, topic(run_id))

  def broadcast(run_id, message) do
    Phoenix.PubSub.broadcast(Haven.PubSub, topic(run_id), message)
  end

  defp topic(run_id), do: "runs:#{run_id}"
end
