defmodule Haven.AgentProbeReport do
  @moduledoc """
  Validates committed `mix haven.agent_probe --report` artifacts.

  This is intentionally stricter than the probe runner itself. Stub and local
  harness reports are useful while developing, but committed production-grade
  evidence should prove a real configured ACP command passed an explicit
  acceptance contract.
  """

  @accepted_statuses ~w(idle closed failed)
  @required_lifecycle_events ~w(
    run_created
    agent_process_started
    agent_initialized
    agent_session_started
    turn_started
    user_message
    turn_finished
  )

  @spec validate_file(Path.t()) :: :ok | {:error, [String.t()]}
  def validate_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, report} <- Jason.decode(content) do
      validate(report)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, ["invalid JSON: #{Exception.message(error)}"]}

      {:error, reason} ->
        {:error, ["could not read report: #{inspect(reason)}"]}
    end
  end

  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(report) when is_map(report) do
    errors =
      []
      |> require_string(report, "run_id")
      |> require_string(report, "agent")
      |> reject_stub_agent(report)
      |> require_string(report, "workspace")
      |> require_string(report, "prompt")
      |> require_accepted_status(report)
      |> require_real_agent_evidence(report)
      |> require_expected_events(report)
      |> require_expected_event_fields(report)
      |> require_capability_event_field_expectations(report)
      |> require_no_missing_events(report)
      |> require_no_missing_event_fields(report)
      |> require_no_errors(report)
      |> require_events(report)
      |> require_lifecycle_events(report)
      |> require_report_identity_events(report)
      |> require_expected_events_present(report)
      |> require_expected_event_fields_present(report)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate(_report), do: {:error, ["report must be a JSON object"]}

  defp require_string(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) ->
        if non_blank_string?(value) do
          errors
        else
          invalid_string(errors, key)
        end

      _value ->
        invalid_string(errors, key)
    end
  end

  defp invalid_string(errors, key), do: ["#{key} must be a non-empty string" | errors]

  defp reject_stub_agent(errors, %{"agent" => "stub-acp"}) do
    ["agent must not be stub-acp" | errors]
  end

  defp reject_stub_agent(errors, _report), do: errors

  defp require_accepted_status(errors, report) do
    case Map.get(report, "status") do
      status when status in @accepted_statuses -> errors
      _status -> ["status must be one of #{Enum.join(@accepted_statuses, ", ")}" | errors]
    end
  end

  defp require_real_agent_evidence(errors, report) do
    case Map.get(report, "real_agent_evidence") do
      %{"required" => true, "accepted" => true} -> errors
      _value -> ["real_agent_evidence must have required=true and accepted=true" | errors]
    end
  end

  defp require_expected_events(errors, report) do
    case Map.get(report, "expected_events") do
      events when is_list(events) and events != [] ->
        if Enum.all?(events, &non_blank_string?/1) do
          errors
        else
          ["expected_events must be a non-empty list of event names" | errors]
        end

      _events ->
        ["expected_events must be a non-empty list of event names" | errors]
    end
  end

  defp require_no_missing_events(errors, report) do
    case Map.get(report, "missing_expected_events") do
      [] -> errors
      _events -> ["missing_expected_events must be empty" | errors]
    end
  end

  defp require_expected_event_fields(errors, report) do
    case Map.get(report, "expected_event_fields", []) do
      fields when is_list(fields) ->
        Enum.reduce(Enum.with_index(fields, 1), errors, fn {field, index}, acc ->
          validate_event_field_expectation(acc, field, index)
        end)

      _fields ->
        ["expected_event_fields must be a list when present" | errors]
    end
  end

  defp require_capability_event_field_expectations(errors, report) do
    expected_events =
      report
      |> Map.get("expected_events", [])
      |> Enum.filter(&is_binary/1)

    expected_event_field_types =
      report
      |> Map.get("expected_event_fields", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "event"))
      |> MapSet.new()

    missing =
      expected_events
      |> Enum.filter(&client_capability_event?/1)
      |> Enum.reject(&MapSet.member?(expected_event_field_types, &1))

    if missing == [] do
      errors
    else
      [
        "client capability expected events require matching expected_event_fields: #{Enum.join(missing, ", ")}"
        | errors
      ]
    end
  end

  defp client_capability_event?(type) do
    String.starts_with?(type, "file_") or String.starts_with?(type, "terminal_")
  end

  defp validate_event_field_expectation(
         errors,
         %{"event" => event, "field" => field, "value" => value},
         index
       ) do
    if non_blank_string?(event) and non_blank_string?(field) and is_binary(value) do
      errors
    else
      invalid_event_field_expectation(errors, index)
    end
  end

  defp validate_event_field_expectation(errors, _field, index) do
    invalid_event_field_expectation(errors, index)
  end

  defp invalid_event_field_expectation(errors, index) do
    [
      "expected_event_fields entry #{index} must include string event, field, and value"
      | errors
    ]
  end

  defp require_no_missing_event_fields(errors, report) do
    case Map.get(report, "missing_expected_event_fields", []) do
      [] -> errors
      _fields -> ["missing_expected_event_fields must be empty" | errors]
    end
  end

  defp require_no_errors(errors, report) do
    case Map.get(report, "errors", %{}) do
      errors_map when errors_map in [%{}, nil] -> errors
      _errors -> ["errors must be empty or absent" | errors]
    end
  end

  defp require_events(errors, report) do
    case Map.get(report, "events") do
      events when is_list(events) and events != [] ->
        Enum.reduce(Enum.with_index(events, 1), errors, fn {event, index}, acc ->
          validate_event(acc, event, index)
        end)

      _events ->
        ["events must be a non-empty list" | errors]
    end
  end

  defp validate_event(errors, %{"seq" => seq, "type" => type, "payload" => payload}, index)
       when is_integer(seq) and is_binary(type) and is_map(payload) do
    cond do
      String.trim(type) == "" ->
        ["event #{index} must include non-empty string type" | errors]

      seq != index ->
        ["event seq #{seq} must match ordered position #{index}" | errors]

      true ->
        errors
    end
  end

  defp validate_event(errors, _event, index) do
    ["event #{index} must include integer seq, string type, and object payload" | errors]
  end

  defp require_lifecycle_events(errors, report) do
    present_events =
      report
      |> Map.get("events", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "type"))
      |> MapSet.new()

    missing =
      @required_lifecycle_events
      |> Enum.reject(&MapSet.member?(present_events, &1))

    if missing == [] do
      errors
    else
      ["events must include full Haven run lifecycle: #{Enum.join(missing, ", ")}" | errors]
    end
  end

  defp require_report_identity_events(errors, report) do
    events = Map.get(report, "events", [])

    errors
    |> require_run_created_identity(report, events)
    |> require_user_message_prompt(report, events)
  end

  defp require_run_created_identity(errors, report, events) do
    case Enum.find(events, &match?(%{"type" => "run_created"}, &1)) do
      %{"payload" => %{"agent" => agent, "workspace" => workspace}} ->
        errors
        |> require_matching_event_value(agent, report["agent"], "run_created payload agent")
        |> require_matching_event_value(
          workspace,
          report["workspace"],
          "run_created payload workspace"
        )

      _event ->
        ["run_created event must include matching agent and workspace payload" | errors]
    end
  end

  defp require_user_message_prompt(errors, report, events) do
    case Enum.find(events, &match?(%{"type" => "user_message"}, &1)) do
      %{"payload" => %{"text" => prompt}} ->
        require_matching_event_value(
          errors,
          prompt,
          report["prompt"],
          "user_message payload text"
        )

      _event ->
        ["user_message event must include matching prompt text payload" | errors]
    end
  end

  defp require_matching_event_value(errors, value, expected, label) do
    if value == expected do
      errors
    else
      ["#{label} must match report metadata" | errors]
    end
  end

  defp require_expected_events_present(errors, report) do
    expected_events = Map.get(report, "expected_events", [])

    present_events =
      report
      |> Map.get("events", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "type"))
      |> MapSet.new()

    missing =
      expected_events
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&MapSet.member?(present_events, &1))

    if missing == [] do
      errors
    else
      ["expected events are absent from events: #{Enum.join(missing, ", ")}" | errors]
    end
  end

  defp require_expected_event_fields_present(errors, report) do
    expected_event_fields = Map.get(report, "expected_event_fields", [])
    events = Map.get(report, "events", [])

    missing =
      expected_event_fields
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&event_field_present?(events, &1))

    if missing == [] do
      errors
    else
      [
        "expected event fields are absent from events: #{Enum.map_join(missing, ", ", &event_field_label/1)}"
        | errors
      ]
    end
  end

  defp event_field_present?(events, %{"event" => event_type, "field" => field, "value" => value}) do
    path = String.split(field, ".", trim: true)

    Enum.any?(events, fn
      %{"type" => ^event_type, "payload" => payload} when is_map(payload) ->
        to_string(get_in(payload, path) || "") == value

      _event ->
        false
    end)
  end

  defp event_field_label(%{"event" => event, "field" => field, "value" => value}) do
    "#{event}:#{field}=#{value}"
  end

  defp non_blank_string?(value), do: is_binary(value) and String.trim(value) != ""
end
