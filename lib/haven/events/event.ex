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
    |> validate_payload_schema()
    |> unique_constraint([:run_id, :seq])
  end

  defp validate_payload_schema(changeset) do
    type = get_field(changeset, :type)

    validate_change(changeset, :payload, fn :payload, payload ->
      payload_schema_errors(type, payload)
    end)
  end

  defp payload_schema_errors(type, payload) when is_map(payload) do
    required_string_fields(type)
    |> Enum.flat_map(&required_string_error(payload, &1))
    |> Kernel.++(required_id_errors(type, payload))
    |> Kernel.++(required_map_errors(type, payload))
    |> Kernel.++(required_list_errors(type, payload))
  end

  defp payload_schema_errors(_type, _payload), do: []

  defp required_string_fields("run_created"), do: ["title", "workspace", "agent"]
  defp required_string_fields("user_message"), do: ["text"]
  defp required_string_fields("agent_message_chunk"), do: ["text"]
  defp required_string_fields("turn_started"), do: ["prompt"]
  defp required_string_fields("agent_session_started"), do: ["agent_session_id"]
  defp required_string_fields("agent_session_loaded"), do: ["agent_session_id"]
  defp required_string_fields("session_load_skipped"), do: ["agent_session_id", "reason"]
  defp required_string_fields("session_load_failed"), do: ["agent_session_id", "error"]
  defp required_string_fields("session_mode_changed"), do: ["agent_session_id", "mode_id"]
  defp required_string_fields("session_mode_rejected"), do: ["mode_id", "reason"]
  defp required_string_fields("session_mode_failed"), do: ["mode_id", "error"]
  defp required_string_fields("session_replay_settled"), do: ["agent_session_id"]
  defp required_string_fields("recovery_prompt_abandoned"), do: ["reason"]
  defp required_string_fields("permission_resolved"), do: ["outcome"]
  defp required_string_fields("capability_policy_applied"), do: ["capability", "decision"]
  defp required_string_fields(_type), do: []

  defp required_id_fields(type) when type in ["permission_requested", "permission_resolved"],
    do: ["request_id"]

  defp required_id_fields(_type), do: []

  defp required_map_fields("permission_requested"), do: ["toolCall"]
  defp required_map_fields("session_replay_settled"), do: ["folded"]
  defp required_map_fields(_type), do: []

  defp required_list_fields(_type), do: []

  defp required_string_error(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) and value != "" -> []
      _value -> [payload: "for this event type, #{field} must be a non-empty string"]
    end
  end

  defp required_id_errors(type, payload) do
    Enum.flat_map(required_id_fields(type), fn field ->
      case Map.get(payload, field) do
        value when is_binary(value) and value != "" ->
          []

        value when is_integer(value) ->
          []

        _value ->
          [payload: "for this event type, #{field} must be a non-empty string or integer"]
      end
    end)
  end

  defp required_map_errors(type, payload) do
    Enum.flat_map(required_map_fields(type), fn field ->
      case Map.get(payload, field) do
        value when is_map(value) -> []
        _value -> [payload: "for this event type, #{field} must be an object"]
      end
    end)
  end

  defp required_list_errors(type, payload) do
    Enum.flat_map(required_list_fields(type), fn field ->
      case Map.get(payload, field) do
        value when is_list(value) -> []
        _value -> [payload: "for this event type, #{field} must be a list"]
      end
    end)
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
