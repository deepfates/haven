defmodule Haven.Events do
  import Ecto.Query

  alias Haven.Events.Event
  alias Haven.Repo

  def append!(run_id, type, payload \\ %{}) do
    payload = normalize_payload(payload)

    seq =
      Repo.one(
        from e in Event,
          where: e.run_id == ^run_id,
          select: coalesce(max(e.seq), 0)
      ) + 1

    %Event{}
    |> Event.changeset(%{run_id: run_id, seq: seq, type: type, payload: payload})
    |> Repo.insert!()
    |> tap(fn event ->
      broadcast(run_id, {:event_appended, event})
      Phoenix.PubSub.broadcast(Haven.PubSub, "runs", {:run_event_appended, event})
    end)
  end

  def list_for_run(run_id) do
    Repo.all(from e in Event, where: e.run_id == ^run_id, order_by: [asc: e.seq])
  end

  def latest_by_run_id(run_ids) when is_list(run_ids) do
    run_ids = Enum.uniq(run_ids)

    Event
    |> where([e], e.run_id in ^run_ids)
    |> order_by([e], desc: e.seq)
    |> Repo.all()
    |> Enum.reduce(%{}, fn event, acc ->
      Map.put_new(acc, event.run_id, event)
    end)
  end

  def subscribe(run_id), do: Phoenix.PubSub.subscribe(Haven.PubSub, topic(run_id))

  def broadcast(run_id, message) do
    Phoenix.PubSub.broadcast(Haven.PubSub, topic(run_id), message)
  end

  defp topic(run_id), do: "runs:#{run_id}"

  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), normalize_payload_value(value)} end)
  end

  defp normalize_payload_value(value) when is_map(value), do: normalize_payload(value)

  defp normalize_payload_value(value) when is_list(value) do
    Enum.map(value, &normalize_payload_value/1)
  end

  defp normalize_payload_value(value), do: value
end
