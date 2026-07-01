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

  @spec validate_failure_file(Path.t()) :: :ok | {:error, [String.t()]}
  def validate_failure_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, report} <- Jason.decode(content) do
      validate_failure(report)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, ["invalid JSON: #{Exception.message(error)}"]}

      {:error, reason} ->
        {:error, ["could not read report: #{inspect(reason)}"]}
    end
  end

  @spec validate_load_file(Path.t()) :: :ok | {:error, [String.t()]}
  def validate_load_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, report} <- Jason.decode(content) do
      validate_load(report)
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
      |> require_redactions(report)
      |> require_expected_events(report)
      |> require_expected_event_fields(report)
      |> require_expected_output(report)
      |> require_capability_event_field_expectations(report)
      |> require_no_missing_events(report)
      |> require_no_missing_event_fields(report)
      |> require_no_missing_output(report)
      |> require_no_errors(report)
      |> require_events(report)
      |> require_lifecycle_events(report)
      |> require_report_identity_events(report)
      |> require_expected_events_present(report)
      |> require_expected_event_fields_present(report)
      |> require_expected_output_present(report)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate(_report), do: {:error, ["report must be a JSON object"]}

  @spec validate_failure(map()) :: :ok | {:error, [String.t()]}
  def validate_failure(report) when is_map(report) do
    errors =
      []
      |> require_string(report, "run_id")
      |> require_string(report, "agent")
      |> reject_stub_agent(report)
      |> require_string(report, "workspace")
      |> require_string(report, "prompt")
      |> require_accepted_status(report)
      |> require_real_agent_evidence(report)
      |> require_redactions(report)
      |> require_expected_events(report)
      |> require_expected_event_fields(report)
      |> require_expected_output(report)
      |> require_any_capability_event_field_expectation(report)
      |> require_missing_events(report)
      |> require_no_missing_event_fields(report)
      |> require_no_missing_output(report)
      |> require_no_errors(report)
      |> require_events(report)
      |> require_lifecycle_events(report)
      |> require_report_identity_events(report)
      |> require_expected_events_absent(report)
      |> require_expected_output_present(report)
      |> require_tool_call_gap_diagnostic(report)
      |> require_unsupported_client_capabilities(report)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate_failure(_report), do: {:error, ["report must be a JSON object"]}

  @spec validate_load(map()) :: :ok | {:error, [String.t()]}
  def validate_load(report) when is_map(report) do
    errors =
      []
      |> require_load_kind(report)
      |> require_string(report, "agent")
      |> reject_stub_agent(report)
      |> require_string(report, "workspace")
      |> require_string(report, "prompt")
      |> require_real_agent_load(report)
      |> require_positive_integer(report, "run_count", 2)
      |> require_optional_load_concurrency(report)
      |> require_concurrent_child_windows(report)
      |> require_load_status(report)
      |> require_expected_events(report)
      |> require_expected_event_fields(report)
      |> require_expected_output(report)
      |> require_load_reports(report)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate_load(_report), do: {:error, ["report must be a JSON object"]}

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

  defp require_load_kind(errors, report) do
    case Map.get(report, "kind") do
      "agent_probe_load" -> errors
      _kind -> ["kind must be agent_probe_load" | errors]
    end
  end

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

  defp require_load_status(errors, report) do
    case Map.get(report, "status") do
      "passed" -> errors
      _status -> ["status must be passed" | errors]
    end
  end

  defp require_positive_integer(errors, report, key, minimum) do
    case Map.get(report, key) do
      value when is_integer(value) and value >= minimum ->
        errors

      _value ->
        ["#{key} must be an integer >= #{minimum}" | errors]
    end
  end

  defp require_optional_load_concurrency(errors, report) do
    case Map.fetch(report, "concurrency") do
      {:ok, value} when is_integer(value) and value >= 1 ->
        case Map.get(report, "run_count") do
          count when is_integer(count) and value <= count ->
            errors

          count when is_integer(count) ->
            ["concurrency must be <= run_count" | errors]

          _count ->
            errors
        end

      {:ok, _value} ->
        ["concurrency must be an integer >= 1" | errors]

      :error ->
        errors
    end
  end

  defp require_concurrent_child_windows(errors, %{"concurrency" => concurrency} = report)
       when is_integer(concurrency) and concurrency > 1 do
    windows = Map.get(report, "child_windows")
    run_count = Map.get(report, "run_count")

    cond do
      not is_list(windows) or windows == [] ->
        ["child_windows must be a non-empty list when concurrency > 1" | errors]

      is_integer(run_count) and length(windows) != run_count ->
        ["child_windows length must match run_count" | errors]

      not Enum.all?(windows, &valid_child_window?/1) ->
        [
          "child_windows entries must include index, run_id, status, started_at, and finished_at"
          | errors
        ]

      not overlapping_child_windows?(windows) ->
        [
          "child_windows must show at least two overlapping child probe windows when concurrency > 1"
          | errors
        ]

      true ->
        errors
    end
  end

  defp require_concurrent_child_windows(errors, _report), do: errors

  defp valid_child_window?(%{
         "index" => index,
         "run_id" => run_id,
         "status" => status,
         "started_at" => started_at,
         "finished_at" => finished_at
       }) do
    is_integer(index) and non_blank_string?(run_id) and non_blank_string?(status) and
      valid_datetime?(started_at) and valid_datetime?(finished_at)
  end

  defp valid_child_window?(_window), do: false

  defp valid_datetime?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_datetime?(_value), do: false

  defp overlapping_child_windows?(windows) do
    parsed =
      Enum.map(windows, fn window ->
        {:ok, started_at, _offset} = DateTime.from_iso8601(window["started_at"])
        {:ok, finished_at, _offset} = DateTime.from_iso8601(window["finished_at"])
        {started_at, finished_at}
      end)

    parsed
    |> pairs()
    |> Enum.any?(fn {{start_a, finish_a}, {start_b, finish_b}} ->
      DateTime.compare(start_a, finish_b) == :lt and DateTime.compare(start_b, finish_a) == :lt
    end)
  end

  defp pairs([]), do: []
  defp pairs([_one]), do: []
  defp pairs([head | tail]), do: Enum.map(tail, &{head, &1}) ++ pairs(tail)

  defp require_real_agent_load(errors, report) do
    case Map.get(report, "reports") do
      reports when is_list(reports) ->
        if Enum.all?(reports, &real_agent_report?/1) do
          errors
        else
          [
            "all load child reports must have required=true and accepted=true real_agent_evidence"
            | errors
          ]
        end

      _reports ->
        errors
    end
  end

  defp real_agent_report?(%{"real_agent_evidence" => %{"required" => true, "accepted" => true}}),
    do: true

  defp real_agent_report?(_report), do: false

  defp require_real_agent_evidence(errors, report) do
    case Map.get(report, "real_agent_evidence") do
      %{"required" => true, "accepted" => true} -> errors
      _value -> ["real_agent_evidence must have required=true and accepted=true" | errors]
    end
  end

  defp require_redactions(errors, report) do
    case Map.get(report, "redactions") do
      redactions when is_list(redactions) ->
        Enum.reduce(Enum.with_index(redactions, 1), errors, fn {redaction, index}, acc ->
          validate_redaction(acc, redaction, index)
        end)

      _redactions ->
        ["redactions must be a list" | errors]
    end
  end

  defp validate_redaction(errors, %{"source" => "literal"} = redaction, index) do
    reject_redaction_value(errors, redaction, index)
  end

  defp validate_redaction(errors, %{"source" => "env", "name" => name} = redaction, index) do
    errors
    |> then(fn errors ->
      if non_blank_string?(name) do
        errors
      else
        ["redactions entry #{index} env name must be a non-empty string" | errors]
      end
    end)
    |> reject_redaction_value(redaction, index)
  end

  defp validate_redaction(errors, _redaction, index) do
    [
      "redactions entry #{index} must be literal or env metadata without secret values"
      | errors
    ]
  end

  defp reject_redaction_value(errors, redaction, index) do
    if Map.has_key?(redaction, "value") do
      ["redactions entry #{index} must not include raw secret value" | errors]
    else
      errors
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

  defp require_missing_events(errors, report) do
    case Map.get(report, "missing_expected_events") do
      events when is_list(events) and events != [] ->
        errors
        |> then(fn errors ->
          if Enum.all?(events, &non_blank_string?/1) do
            errors
          else
            ["missing_expected_events must be a non-empty list of event names" | errors]
          end
        end)
        |> then(fn errors ->
          if Enum.any?(events, &client_capability_event?/1) do
            errors
          else
            [
              "missing_expected_events must include at least one client capability event"
              | errors
            ]
          end
        end)

      _events ->
        ["missing_expected_events must be a non-empty list of event names" | errors]
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

  defp require_expected_output(errors, report) do
    case Map.get(report, "expected_output", %{}) do
      output when is_map(output) ->
        Enum.reduce(output, errors, fn
          {key, value}, acc
          when key in ["min_agent_output_chars", "min_agent_message_chunks"] and
                 is_integer(value) and value >= 1 ->
            acc

          {key, _value}, acc when key in ["min_agent_output_chars", "min_agent_message_chunks"] ->
            ["expected_output #{key} must be an integer >= 1" | acc]

          {key, _value}, acc ->
            ["expected_output contains unsupported key #{key}" | acc]
        end)

      _output ->
        ["expected_output must be a map when present" | errors]
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

  defp require_any_capability_event_field_expectation(errors, report) do
    expected_capability_events =
      report
      |> Map.get("expected_events", [])
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&client_capability_event?/1)
      |> MapSet.new()

    expected_event_field_types =
      report
      |> Map.get("expected_event_fields", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "event"))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    if MapSet.disjoint?(expected_capability_events, expected_event_field_types) do
      [
        "failure reports for client capability gaps require at least one matching expected_event_fields entry"
        | errors
      ]
    else
      errors
    end
  end

  defp client_capability_event?(type) do
    String.starts_with?(type, "file_") or String.starts_with?(type, "terminal_")
  end

  defp client_capability_family("file_read" <> _suffix), do: "fs/read_text_file"
  defp client_capability_family("file_write" <> _suffix), do: "fs/write_text_file"
  defp client_capability_family("terminal_" <> _suffix), do: "terminal"
  defp client_capability_family("file_" <> _suffix), do: "fs"

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

  defp require_no_missing_output(errors, report) do
    case Map.get(report, "missing_expected_output", []) do
      [] -> errors
      _output -> ["missing_expected_output must be empty" | errors]
    end
  end

  defp require_no_errors(errors, report) do
    case Map.get(report, "errors", %{}) do
      errors_map when errors_map in [%{}, nil] -> errors
      _errors -> ["errors must be empty or absent" | errors]
    end
  end

  defp require_load_reports(errors, report) do
    reports = Map.get(report, "reports")
    run_count = Map.get(report, "run_count")

    cond do
      not is_list(reports) or reports == [] ->
        ["reports must be a non-empty list" | errors]

      is_integer(run_count) and length(reports) != run_count ->
        [
          "reports length must match run_count"
          | validate_load_child_reports(errors, report, reports)
        ]

      true ->
        validate_load_child_reports(errors, report, reports)
    end
  end

  defp validate_load_child_reports(errors, load_report, reports) do
    child_errors =
      reports
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {report, index} ->
        case validate(report) do
          :ok ->
            load_child_identity_errors(load_report, report, index)

          {:error, errors} ->
            Enum.map(errors, &"child report #{index}: #{&1}")
        end
      end)

    duplicate_errors = duplicate_run_id_errors(reports)

    child_errors ++ duplicate_errors ++ errors
  end

  defp load_child_identity_errors(load_report, child, index) do
    []
    |> then(fn errors ->
      if child["agent"] == load_report["agent"] do
        errors
      else
        ["child report #{index}: agent must match load report"]
      end
    end)
    |> then(fn errors ->
      if child["workspace"] == load_report["workspace"] do
        errors
      else
        ["child report #{index}: workspace must match load report" | errors]
      end
    end)
    |> then(fn errors ->
      if child["prompt"] == load_report["prompt"] do
        errors
      else
        ["child report #{index}: prompt must match load report" | errors]
      end
    end)
  end

  defp duplicate_run_id_errors(reports) do
    run_ids =
      reports
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "run_id"))
      |> Enum.filter(&non_blank_string?/1)

    duplicates =
      run_ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_run_id, count} -> count > 1 end)
      |> Enum.map(fn {run_id, _count} -> run_id end)

    if duplicates == [] do
      []
    else
      ["load child reports must have distinct run_ids: #{Enum.join(duplicates, ", ")}"]
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

  defp require_expected_events_absent(errors, report) do
    expected_events = Map.get(report, "expected_events", [])
    declared_missing = Map.get(report, "missing_expected_events", [])

    present_events =
      report
      |> Map.get("events", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "type"))
      |> MapSet.new()

    actual_missing =
      expected_events
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&MapSet.member?(present_events, &1))

    cond do
      Enum.sort(actual_missing) == Enum.sort(declared_missing) ->
        errors

      actual_missing == [] ->
        ["failure report must have at least one expected event absent from events" | errors]

      true ->
        [
          "missing_expected_events must match absent expected events: #{Enum.join(actual_missing, ", ")}"
          | errors
        ]
    end
  end

  defp require_tool_call_gap_diagnostic(errors, report) do
    diagnostics = Map.get(report, "diagnostics", [])
    declared_missing = Map.get(report, "missing_expected_events", [])
    present_events = present_event_set(report)

    diagnostic =
      Enum.find(diagnostics, fn
        %{"type" => "tool_call_only_capability_gap"} -> true
        _diagnostic -> false
      end)

    case diagnostic do
      %{
        "missing_events" => missing_events,
        "observed_events" => observed_events,
        "message" => message
      }
      when is_list(missing_events) and is_list(observed_events) and is_binary(message) ->
        errors
        |> require_diagnostic_missing_events(missing_events, declared_missing)
        |> require_diagnostic_observed_events(observed_events, present_events)

      _diagnostic ->
        [
          "failure report must include a tool_call_only_capability_gap diagnostic with missing_events and observed_events"
          | errors
        ]
    end
  end

  defp require_unsupported_client_capabilities(errors, report) do
    declared_missing = Map.get(report, "missing_expected_events", [])
    present_events = present_event_set(report)

    expected =
      declared_missing
      |> Enum.filter(&client_capability_event?/1)
      |> Enum.group_by(&client_capability_family/1)
      |> Map.new(fn {capability, events} -> {capability, MapSet.new(events)} end)

    case Map.get(report, "unsupported_client_capabilities") do
      capabilities when is_list(capabilities) and capabilities != [] ->
        capabilities
        |> Enum.with_index(1)
        |> Enum.reduce(errors, fn {capability, index}, acc ->
          validate_unsupported_client_capability(
            acc,
            capability,
            index,
            expected,
            present_events
          )
        end)
        |> require_declared_unsupported_capability_families(capabilities, expected)

      _capabilities ->
        [
          "unsupported_client_capabilities must declare unsupported mediated capability families"
          | errors
        ]
    end
  end

  defp require_declared_unsupported_capability_families(errors, capabilities, expected) do
    declared =
      capabilities
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "capability"))
      |> MapSet.new()

    missing =
      expected
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(declared, &1))

    if missing == [] do
      errors
    else
      [
        "unsupported_client_capabilities must declare missing capability families: #{Enum.join(missing, ", ")}"
        | errors
      ]
    end
  end

  defp validate_unsupported_client_capability(
         errors,
         %{
           "capability" => capability,
           "reason" => reason,
           "missing_events" => missing_events,
           "observed_events" => observed_events
         },
         _index,
         expected,
         present_events
       )
       when is_binary(capability) and is_binary(reason) and is_list(missing_events) and
              is_list(observed_events) do
    errors
    |> then(fn errors ->
      if non_blank_string?(capability) and non_blank_string?(reason) do
        errors
      else
        ["unsupported_client_capabilities entries must include capability and reason" | errors]
      end
    end)
    |> then(fn errors ->
      expected_events = Map.get(expected, capability, MapSet.new())
      missing_set = MapSet.new(missing_events)

      cond do
        missing_events == [] ->
          [
            "unsupported_client_capabilities #{capability} missing_events must not be empty"
            | errors
          ]

        not Enum.all?(missing_events, &client_capability_event?/1) ->
          [
            "unsupported_client_capabilities #{capability} missing_events must be client capability events"
            | errors
          ]

        not MapSet.subset?(missing_set, expected_events) ->
          [
            "unsupported_client_capabilities #{capability} missing_events must be declared missing expected events"
            | errors
          ]

        true ->
          errors
      end
    end)
    |> require_diagnostic_observed_events(observed_events, present_events)
  end

  defp validate_unsupported_client_capability(
         errors,
         _capability,
         index,
         _expected,
         _present_events
       ) do
    [
      "unsupported_client_capabilities entry #{index} must include capability, reason, missing_events, and observed_events"
      | errors
    ]
  end

  defp require_diagnostic_missing_events(errors, missing_events, declared_missing) do
    missing_set = MapSet.new(missing_events)
    declared_set = MapSet.new(declared_missing)

    cond do
      missing_events == [] ->
        ["tool_call_only_capability_gap missing_events must not be empty" | errors]

      not Enum.all?(missing_events, &client_capability_event?/1) ->
        ["tool_call_only_capability_gap missing_events must be client capability events" | errors]

      not MapSet.subset?(missing_set, declared_set) ->
        [
          "tool_call_only_capability_gap missing_events must be listed in missing_expected_events"
          | errors
        ]

      true ->
        errors
    end
  end

  defp require_diagnostic_observed_events(errors, observed_events, present_events) do
    observed_set = MapSet.new(observed_events)

    cond do
      not MapSet.member?(observed_set, "tool_call") and
          not MapSet.member?(observed_set, "tool_call_update") ->
        [
          "tool_call_only_capability_gap observed_events must include tool_call or tool_call_update"
          | errors
        ]

      not Enum.all?(observed_events, &MapSet.member?(present_events, &1)) ->
        [
          "tool_call_only_capability_gap observed_events must be present in events"
          | errors
        ]

      true ->
        errors
    end
  end

  defp present_event_set(report) do
    report
    |> Map.get("events", [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, "type"))
    |> MapSet.new()
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

  defp require_expected_output_present(errors, report) do
    expected_output = Map.get(report, "expected_output", %{})
    metrics = Map.get(report, "agent_output_metrics", %{})

    errors
    |> require_output_metric(
      expected_output,
      metrics,
      "min_agent_output_chars",
      "text_char_count"
    )
    |> require_output_metric(
      expected_output,
      metrics,
      "min_agent_message_chunks",
      "message_chunk_count"
    )
  end

  defp require_output_metric(errors, expected_output, metrics, expected_key, metric_key) do
    case Map.fetch(expected_output, expected_key) do
      {:ok, expected} when is_integer(expected) ->
        case Map.get(metrics, metric_key) do
          actual when is_integer(actual) and actual >= expected ->
            errors

          actual when is_integer(actual) ->
            [
              "agent_output_metrics #{metric_key} must be >= expected_output #{expected_key}"
              | errors
            ]

          _actual ->
            ["agent_output_metrics #{metric_key} must be an integer" | errors]
        end

      _other ->
        errors
    end
  end

  defp event_field_present?(events, %{"event" => event_type, "field" => field, "value" => value}) do
    path = field_path(field)

    Enum.any?(events, fn
      %{"type" => ^event_type, "payload" => payload} when is_map(payload) ->
        to_string(get_in(payload, path) || "") == value

      _event ->
        false
    end)
  end

  defp field_path(field) do
    field
    |> String.split(".", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> strip_payload_prefix()
  end

  defp strip_payload_prefix(["payload" | rest]), do: rest
  defp strip_payload_prefix(path), do: path

  defp event_field_label(%{"event" => event, "field" => field, "value" => value}) do
    "#{event}:#{field}=#{value}"
  end

  defp non_blank_string?(value), do: is_binary(value) and String.trim(value) != ""
end
