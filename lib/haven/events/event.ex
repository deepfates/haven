defmodule Haven.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "events" do
    field :seq, :integer
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :run, Haven.Runs.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :type, :payload])
    |> update_change(:type, &String.trim/1)
    |> validate_required([:run_id, :seq, :type, :payload])
    |> validate_change(:payload, fn :payload, payload ->
      if json_payload?(payload) do
        []
      else
        [payload: "must contain only JSON-compatible values"]
      end
    end)
    |> unique_constraint([:run_id, :seq])
  end

  defp json_payload?(value)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: true

  defp json_payload?(value) when is_list(value), do: Enum.all?(value, &json_payload?/1)

  defp json_payload?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, value} ->
        is_binary(key) and json_payload?(value)
      end)
  end

  defp json_payload?(_value), do: false
end
