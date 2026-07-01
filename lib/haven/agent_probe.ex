defmodule Haven.AgentProbe do
  @moduledoc """
  Runs an end-to-end Haven run against a configured ACP agent.

  The probe intentionally goes through `Haven.Runs` instead of talking directly
  to an agent process, so it exercises the same app path as the browser UI:
  run creation, agent boot, ACP initialization, prompting, permission
  resolution, status projection, and durable event storage.
  """

  alias Haven.Events
  alias Haven.Agents
  alias Haven.Runs

  @terminal_statuses ~w(closed failed)
  @default_timeout 30_000

  @type permission_resolution :: nil | String.t()

  @type report :: %{
          run_id: String.t(),
          agent: String.t(),
          workspace: String.t(),
          status: String.t(),
          events: [map()],
          prompt: String.t(),
          expected_events: [String.t()],
          missing_expected_events: [String.t()],
          diagnostics: [map()]
        }

  @spec run(keyword()) :: {:ok, report()} | {:error, atom(), report()}
  def run(opts) do
    agent = Keyword.get(opts, :agent, "stub-acp")
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    prompt = Keyword.get(opts, :prompt, "hello from Haven agent probe")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    permission_resolution = Keyword.get(opts, :resolve_permissions)
    capability_policy = capability_policy(opts)
    redactions = redactions(opts)
    require_real_agent? = Keyword.get(opts, :require_real_agent, false)

    expected_events =
      Keyword.get_values(opts, :expect_event) ++ Keyword.get(opts, :expect_events, [])

    expected_event_fields = expected_event_fields(opts)
    expected_output = expected_output(opts)

    with {:ok, run} <-
           Runs.create_run(%{
             "title" => Keyword.get(opts, :title, title(agent)),
             "workspace" => workspace,
             "agent" => agent,
             "capability_policy" => capability_policy
           }),
         {:ok, _run} <- wait_for_boot(run.id, timeout),
         :ok <- Runs.send_prompt(run.id, prompt),
         {:ok, finished} <- wait_for_finish(run.id, timeout, permission_resolution) do
      expected_events = Enum.uniq(expected_events)

      finished
      |> redacted_report(
        prompt,
        expected_events,
        expected_event_fields,
        expected_output,
        redactions
      )
      |> validate_expected_events(expected_events)
      |> validate_expected_event_fields(expected_event_fields)
      |> validate_expected_output()
      |> validate_real_agent(require_real_agent?)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, :invalid_run,
         invalid_run_report(
           agent,
           workspace,
           prompt,
           changeset,
           expected_events,
           expected_event_fields,
           expected_output
         )
         |> apply_redactions(redactions)}

      {:error, reason, run_id} ->
        {:error, reason,
         run_id
         |> Runs.get_run!()
         |> redacted_report(
           prompt,
           expected_events,
           expected_event_fields,
           expected_output,
           redactions
         )}

      {:error, reason} ->
        {:error, reason,
         agent
         |> invalid_run_report(
           workspace,
           prompt,
           nil,
           expected_events,
           expected_event_fields,
           expected_output
         )
         |> apply_redactions(redactions)}
    end
  end

  @spec preflight(keyword()) :: {:ok, report()} | {:error, atom(), report()}
  def preflight(opts) do
    agent = Keyword.get(opts, :agent, "stub-acp")
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    redactions = redactions(opts)
    require_real_agent? = Keyword.get(opts, :require_real_agent, false)
    prompt = "(preflight only)"
    expected_events = ["agent_initialized", "agent_session_started"]
    expected_event_fields = []

    result =
      with {:ok, run} <-
             Runs.create_run(%{
               "title" => Keyword.get(opts, :title, preflight_title(agent)),
               "workspace" => workspace,
               "agent" => agent,
               "capability_policy" => capability_policy(opts)
             }),
           {:ok, booted} <- wait_for_boot(run.id, timeout) do
        _ = Runs.stop_run(booted.id)

        booted
        |> redacted_report(prompt, expected_events, expected_event_fields, redactions)
        |> validate_expected_events(expected_events)
        |> validate_real_agent(require_real_agent?)
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, :invalid_run,
           invalid_run_report(
             agent,
             workspace,
             prompt,
             changeset,
             expected_events,
             expected_event_fields
           )
           |> apply_redactions(redactions)}

        {:error, reason, run_id} ->
          _ = Runs.stop_run(run_id)

          {:error, reason,
           run_id
           |> Runs.get_run!()
           |> redacted_report(prompt, expected_events, expected_event_fields, redactions)}

        {:error, reason} ->
          {:error, reason,
           agent
           |> invalid_run_report(workspace, prompt, nil, expected_events, expected_event_fields)
           |> apply_redactions(redactions)}
      end

    result
  end

  @spec run_load(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def run_load(opts) do
    count = Keyword.get(opts, :load_runs, 1)
    concurrency = Keyword.get(opts, :load_concurrency, 1)

    cond do
      not (is_integer(count) and count >= 2) ->
        report =
          load_report(opts, count, concurrency, [], [
            %{index: nil, reason: :invalid_load_runs, run_id: nil}
          ])

        {:error, :invalid_load_runs, report}

      not (is_integer(concurrency) and concurrency >= 1 and concurrency <= count) ->
        report =
          load_report(opts, count, concurrency, [], [
            %{index: nil, reason: :invalid_load_concurrency, run_id: nil}
          ])

        {:error, :invalid_load_concurrency, report}

      true ->
        run_load_runs(opts, count, concurrency)
    end
  end

  defp run_load_runs(opts, count, concurrency) do
    expected_events =
      Keyword.get_values(opts, :expect_event) ++ Keyword.get(opts, :expect_events, [])

    expected_event_fields = expected_event_fields(opts)
    expected_output = expected_output(opts)

    reports =
      1..count
      |> Task.async_stream(
        fn index ->
          run_load_child(opts, index, count)
        end,
        max_concurrency: concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, indexed_result} -> indexed_result
      end)

    child_reports =
      Enum.map(reports, fn
        {_index, {:ok, report}, _window} -> report
        {_index, {:error, _reason, report}, _window} -> report
      end)

    child_windows = Enum.map(reports, fn {_index, _result, window} -> window end)

    failures =
      reports
      |> Enum.flat_map(fn
        {_index, {:ok, _report}, _window} ->
          []

        {index, {:error, reason, report}, _window} ->
          [%{index: index, reason: reason, run_id: report.run_id}]
      end)

    report = %{
      load_report(opts, count, concurrency, child_reports, failures, child_windows)
      | expected_events: Enum.uniq(expected_events),
        expected_event_fields: Enum.map(expected_event_fields, &event_field_report/1),
        expected_output: expected_output_report(expected_output)
    }

    if failures == [] do
      {:ok, report}
    else
      {:error, :load_run_failed, report}
    end
  end

  defp run_load_child(opts, index, count) do
    started_at = DateTime.utc_now()
    result = safe_load_child_run(opts, index, count)
    finished_at = DateTime.utc_now()

    {index, result,
     %{
       index: index,
       started_at: DateTime.to_iso8601(started_at),
       finished_at: DateTime.to_iso8601(finished_at),
       status: load_child_status(result),
       run_id: load_child_run_id(result)
     }}
  end

  defp safe_load_child_run(opts, index, count) do
    run(load_run_opts(opts, index, count))
  rescue
    exception ->
      {:error, :child_exception, load_child_exception_report(opts, exception)}
  catch
    kind, reason ->
      {:error, :child_exception, load_child_exception_report(opts, kind, reason)}
  end

  defp load_child_status({:ok, report}), do: report.status
  defp load_child_status({:error, reason, _report}), do: to_string(reason)

  defp load_child_run_id({:ok, report}), do: report.run_id
  defp load_child_run_id({:error, _reason, report}), do: report.run_id

  defp load_run_opts(opts, index, count) do
    opts
    |> Keyword.delete(:load_runs)
    |> Keyword.delete(:load_concurrency)
    |> Keyword.put(
      :title,
      "#{Keyword.get(opts, :title, title(Keyword.get(opts, :agent, "stub-acp")))} #{index}/#{count}"
    )
  end

  defp load_report(opts, count, concurrency, child_reports, failures, child_windows \\ []) do
    %{
      kind: "agent_probe_load",
      agent: Keyword.get(opts, :agent, "stub-acp"),
      workspace: Keyword.get(opts, :workspace, File.cwd!()),
      prompt: Keyword.get(opts, :prompt, "hello from Haven agent probe"),
      run_count: count,
      concurrency: concurrency,
      status: if(failures == [], do: "passed", else: "failed"),
      expected_events: [],
      expected_event_fields: [],
      expected_output: %{},
      failures: failures,
      child_windows: child_windows,
      reports: child_reports
    }
  end

  defp load_child_exception_report(opts, exception) do
    load_child_exception_report(opts, :error, Exception.message(exception))
  end

  defp load_child_exception_report(opts, kind, reason) do
    expected_events =
      Keyword.get_values(opts, :expect_event) ++ Keyword.get(opts, :expect_events, [])

    expected_event_fields = expected_event_fields(opts)
    expected_output = expected_output(opts)

    opts
    |> Keyword.get(:agent, "stub-acp")
    |> invalid_run_report(
      Keyword.get(opts, :workspace, File.cwd!()),
      Keyword.get(opts, :prompt, "hello from Haven agent probe"),
      nil,
      expected_events,
      expected_event_fields,
      expected_output
    )
    |> Map.put(:status, "failed")
    |> Map.put(:diagnostics, [
      %{
        type: "load_child_exception",
        message: "#{kind}: #{inspect(reason)}"
      }
    ])
    |> apply_redactions(redactions(opts))
  end

  @spec agent_inventory(String.t(), keyword()) :: [map()]
  def agent_inventory(workspace \\ File.cwd!(), opts \\ []) do
    workspace = Path.expand(workspace)

    latest_preflights =
      if Keyword.get(opts, :include_preflight, true) do
        latest_preflights_by_agent(workspace)
      else
        %{}
      end

    Agents.available()
    |> Enum.map(fn {agent, _label} ->
      case Agents.command(agent, workspace) do
        {:ok, command} ->
          rejection_reasons = real_agent_rejection_reasons(agent, command.args)

          %{
            agent: agent,
            status: "ready",
            executable: command.executable,
            args: command.args,
            cwd: command.cwd,
            env_keys: Enum.map(command.env, fn {name, _value} -> name end),
            real_agent_candidate: rejection_reasons == [],
            real_agent_rejection_reasons: rejection_reasons
          }
          |> maybe_put_latest_preflight(Map.get(latest_preflights, agent))

        {:error, reason} ->
          %{
            agent: agent,
            status: "invalid",
            error: agent_command_error_summary(reason),
            real_agent_candidate: false,
            real_agent_rejection_reasons: [agent_command_rejection_reason(reason)]
          }
          |> maybe_put_latest_preflight(Map.get(latest_preflights, agent))
      end
    end)
  end

  defp latest_preflights_by_agent(workspace) do
    runs =
      Runs.list_runs()
      |> Enum.filter(fn run ->
        run.workspace == workspace and String.starts_with?(run.title || "", "Agent preflight: ")
      end)

    latest_events =
      runs
      |> Enum.map(& &1.id)
      |> Events.latest_by_run_id()

    Enum.reduce(runs, %{}, fn run, acc ->
      Map.put_new(acc, run.agent, preflight_summary(run, Map.get(latest_events, run.id)))
    end)
  end

  defp maybe_put_latest_preflight(inventory, nil), do: inventory

  defp maybe_put_latest_preflight(inventory, latest_preflight) do
    Map.put(inventory, :latest_preflight, latest_preflight)
  end

  defp preflight_summary(run, latest_event) do
    %{
      run_id: run.id,
      status: preflight_status(run),
      run_status: run.status,
      checked_at: DateTime.to_iso8601(run.updated_at),
      last_event_type: latest_event && latest_event.type,
      failure_reason: preflight_failure_reason(run, latest_event)
    }
  end

  defp preflight_status(%{status: "idle", agent_session_id: session_id})
       when is_binary(session_id),
       do: "passed"

  defp preflight_status(%{status: "failed"}), do: "failed"
  defp preflight_status(_run), do: "unknown"

  defp preflight_failure_reason(%{status: "failed"}, %{payload: payload}) when is_map(payload) do
    payload["reason"] || payload["error"]
  end

  defp preflight_failure_reason(_run, _latest_event), do: nil

  defp agent_command_error_summary({:missing_executable, executable}) do
    "Missing executable: #{executable}"
  end

  defp agent_command_error_summary({:missing_cwd, cwd}) do
    "Missing working directory: #{cwd}"
  end

  defp agent_command_error_summary({:unknown_agent, agent}) do
    "Unknown agent: #{agent}"
  end

  defp agent_command_error_summary({:invalid_agent_field, field}) do
    "Invalid agent field: #{field}"
  end

  defp agent_command_error_summary(reason), do: inspect(reason)

  defp agent_command_rejection_reason({:missing_executable, _executable}) do
    "agent executable cannot be resolved"
  end

  defp agent_command_rejection_reason({:missing_cwd, _cwd}) do
    "agent working directory does not exist"
  end

  defp agent_command_rejection_reason({:unknown_agent, _agent}) do
    "agent is not configured"
  end

  defp agent_command_rejection_reason({:invalid_agent_field, field}) do
    "agent configuration has invalid #{field}"
  end

  defp agent_command_rejection_reason(_reason), do: "agent command cannot be resolved"

  defp title(agent), do: "Agent probe: #{agent}"
  defp preflight_title(agent), do: "Agent preflight: #{agent}"

  defp capability_policy(opts) do
    base_policy =
      opts
      |> Keyword.get(:capability_policy, %{})
      |> policy_map()

    opts
    |> Enum.reduce(base_policy, fn
      {:file_read_policy, value}, policy -> Map.put(policy, "file_read", value)
      {:file_read_paths, value}, policy -> Map.put(policy, "file_read_paths", value)
      {:file_write_policy, value}, policy -> Map.put(policy, "file_write", value)
      {:file_write_paths, value}, policy -> Map.put(policy, "file_write_paths", value)
      {:terminal_create_policy, value}, policy -> Map.put(policy, "terminal_create", value)
      _option, policy -> policy
    end)
  end

  defp policy_map(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} -> {to_string(key), value} end)
  end

  defp policy_map(policy) when is_list(policy) do
    policy
    |> Enum.filter(fn
      {key, _value} when is_atom(key) or is_binary(key) -> true
      _other -> false
    end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp policy_map(_policy), do: %{}

  defp redactions(opts) do
    literal_redactions =
      opts
      |> Keyword.get_values(:redact)
      |> Enum.map(&%{source: :literal, value: &1})

    env_redactions =
      opts
      |> Keyword.get_values(:redact_env)
      |> Enum.map(fn name ->
        %{source: :env, name: name, value: System.get_env(name)}
      end)

    (literal_redactions ++ env_redactions)
    |> Enum.filter(fn
      %{value: value} when is_binary(value) -> value != ""
      _redaction -> false
    end)
  end

  defp expected_event_fields(opts) do
    opts
    |> Keyword.get_values(:expect_event_field)
    |> Kernel.++(Keyword.get(opts, :expect_event_fields, []))
    |> Enum.map(&normalize_event_field_expectation!/1)
    |> Enum.uniq()
  end

  defp normalize_event_field_expectation!(%{event: event, field: field, value: value}) do
    %{event: to_string(event), field: field_path(field), value: to_string(value)}
  end

  defp normalize_event_field_expectation!(%{"event" => event, "field" => field, "value" => value}) do
    %{event: to_string(event), field: field_path(field), value: to_string(value)}
  end

  defp normalize_event_field_expectation!(spec) when is_binary(spec) do
    with [event, rest] <- String.split(spec, ":", parts: 2),
         [field, value] <- String.split(rest, "=", parts: 2),
         event <- String.trim(event),
         field <- String.trim(field),
         value <- String.trim(value),
         true <- event != "" and field != "" do
      %{event: event, field: field_path(field), value: value}
    else
      _ ->
        raise ArgumentError,
              "expected event field expectation as EVENT:payload.path=value, got: #{inspect(spec)}"
    end
  end

  defp field_path(field) when is_binary(field) do
    field
    |> String.split(".", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> strip_payload_prefix()
  end

  defp field_path(field) when is_list(field) do
    field
    |> Enum.map(&to_string/1)
    |> strip_payload_prefix()
  end

  defp strip_payload_prefix(["payload" | rest]), do: rest
  defp strip_payload_prefix(path), do: path

  defp wait_for_boot(run_id, timeout) do
    wait_until(run_id, timeout, fn run ->
      cond do
        run.status == "idle" and run.agent_session_id -> {:halt, {:ok, run}}
        run.status in @terminal_statuses -> {:halt, {:error, :boot_failed, run.id}}
        true -> :cont
      end
    end)
  end

  defp wait_for_finish(run_id, timeout, permission_resolution) do
    wait_until(run_id, timeout, fn run ->
      cond do
        run.status == "waiting" and is_binary(permission_resolution) ->
          resolve_pending_permissions(run.id, permission_resolution)
          :cont

        run.status == "waiting" ->
          {:halt, {:error, :permission_required, run.id}}

        run.status == "failed" ->
          {:halt, {:error, :run_failed, run.id}}

        run.status == "closed" ->
          {:halt, {:ok, run}}

        run.status == "idle" ->
          {:halt, {:ok, run}}

        true ->
          :cont
      end
    end)
  end

  defp wait_until(run_id, timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(run_id, deadline, fun)
  end

  defp do_wait_until(run_id, deadline, fun) do
    run = Runs.get_run!(run_id)

    case fun.(run) do
      {:halt, result} ->
        result

      :cont ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout, run_id}
        else
          receive do
          after
            50 -> do_wait_until(run_id, deadline, fun)
          end
        end
    end
  end

  defp resolve_pending_permissions(run_id, option_id) do
    run_id
    |> pending_permission_ids()
    |> Enum.each(fn request_id ->
      _ = Runs.resolve_permission(run_id, request_id, option_id)
    end)
  end

  defp pending_permission_ids(run_id) do
    events = Events.list_for_run(run_id)

    resolved =
      events
      |> Enum.filter(&(&1.type in ["permission_resolved", "permission_resolution_ignored"]))
      |> Enum.map(& &1.payload["request_id"])
      |> MapSet.new()

    events
    |> Enum.filter(&(&1.type == "permission_requested"))
    |> Enum.map(& &1.payload["request_id"])
    |> Enum.reject(&MapSet.member?(resolved, &1))
  end

  defp report(run, prompt, expected_events, expected_event_fields, expected_output) do
    events = Events.list_for_run(run.id)

    %{
      run_id: run.id,
      agent: run.agent,
      workspace: run.workspace,
      status: run.status,
      prompt: prompt,
      events: Enum.map(events, &event_report/1),
      expected_events: expected_events,
      missing_expected_events: [],
      diagnostics: [],
      expected_event_fields: Enum.map(expected_event_fields, &event_field_report/1),
      missing_expected_event_fields: [],
      agent_output_metrics: agent_output_metrics(events),
      expected_output: expected_output_report(expected_output),
      missing_expected_output: []
    }
  end

  defp redacted_report(
         run,
         prompt,
         expected_events,
         expected_event_fields,
         expected_output,
         redactions
       ) do
    run
    |> report(prompt, expected_events, expected_event_fields, expected_output)
    |> apply_redactions(redactions)
  end

  defp redacted_report(run, prompt, expected_events, expected_event_fields, redactions) do
    redacted_report(run, prompt, expected_events, expected_event_fields, %{}, redactions)
  end

  defp invalid_run_report(
         agent,
         workspace,
         prompt,
         changeset,
         expected_events,
         expected_event_fields,
         expected_output \\ %{}
       ) do
    %{
      run_id: nil,
      agent: agent,
      workspace: workspace,
      status: "invalid",
      prompt: prompt,
      errors: changeset_errors(changeset),
      events: [],
      expected_events: expected_events,
      missing_expected_events: [],
      diagnostics: [],
      expected_event_fields: Enum.map(expected_event_fields, &event_field_report/1),
      missing_expected_event_fields: Enum.map(expected_event_fields, &event_field_report/1),
      agent_output_metrics: %{message_chunk_count: 0, text_char_count: 0},
      expected_output: expected_output_report(expected_output),
      missing_expected_output:
        expected_output_missing(%{message_chunk_count: 0, text_char_count: 0}, expected_output)
    }
  end

  defp validate_expected_events(report, []), do: {:ok, report}

  defp validate_expected_events(report, expected_events) do
    present = report.events |> Enum.map(& &1.type) |> MapSet.new()

    missing =
      expected_events
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.uniq()

    if missing == [] do
      {:ok, report}
    else
      report =
        report
        |> Map.put(:missing_expected_events, missing)
        |> Map.put(
          :unsupported_client_capabilities,
          unsupported_client_capabilities(missing, report.events)
        )
        |> Map.update(
          :diagnostics,
          event_gap_diagnostics(missing, report.events),
          fn diagnostics ->
            diagnostics ++ event_gap_diagnostics(missing, report.events)
          end
        )

      {:error, :missing_expected_events, report}
    end
  end

  defp event_gap_diagnostics(missing, events) do
    missing_capability_events = Enum.filter(missing, &client_capability_event?/1)
    observed_tool_events = observed_tool_events(events)

    if missing_capability_events != [] and observed_tool_events != [] do
      [
        %{
          type: "tool_call_only_capability_gap",
          message:
            "Expected Haven-mediated client capability events were missing, but generic ACP tool_call activity was observed. This is useful agent evidence, not proof of Haven-mediated fs/* or terminal/* handling.",
          missing_events: missing_capability_events,
          observed_events: observed_tool_events
        }
      ]
    else
      []
    end
  end

  defp unsupported_client_capabilities(missing, events) do
    missing_capability_events = Enum.filter(missing, &client_capability_event?/1)
    observed_tool_events = observed_tool_events(events)

    if missing_capability_events == [] or observed_tool_events == [] do
      []
    else
      missing_capability_events
      |> Enum.group_by(&client_capability_family/1)
      |> Enum.map(fn {capability, events} ->
        %{
          capability: capability,
          reason:
            "Observed generic ACP tool_call activity instead of Haven-mediated client capability events.",
          missing_events: Enum.sort(events),
          observed_events: observed_tool_events
        }
      end)
      |> Enum.sort_by(& &1.capability)
    end
  end

  defp observed_tool_events(events) do
    events
    |> Enum.map(& &1.type)
    |> Enum.filter(&(&1 in ["tool_call", "tool_call_update"]))
    |> Enum.uniq()
  end

  defp client_capability_event?(type) do
    String.starts_with?(type, "file_") or String.starts_with?(type, "terminal_")
  end

  defp client_capability_family("file_read" <> _suffix), do: "fs/read_text_file"
  defp client_capability_family("file_write" <> _suffix), do: "fs/write_text_file"
  defp client_capability_family("terminal_" <> _suffix), do: "terminal"
  defp client_capability_family("file_" <> _suffix), do: "fs"

  defp validate_expected_event_fields({:error, reason, report}, _expected_event_fields),
    do: {:error, reason, report}

  defp validate_expected_event_fields({:ok, report}, []), do: {:ok, report}

  defp validate_expected_event_fields({:ok, report}, expected_event_fields) do
    missing =
      expected_event_fields
      |> Enum.reject(&event_field_present?(report.events, &1))
      |> Enum.map(&event_field_report/1)

    if missing == [] do
      {:ok, report}
    else
      {:error, :missing_expected_event_fields, %{report | missing_expected_event_fields: missing}}
    end
  end

  defp validate_expected_output({:error, reason, report}), do: {:error, reason, report}

  defp validate_expected_output({:ok, report}) do
    missing = expected_output_missing(report.agent_output_metrics, report.expected_output)

    if missing == [] do
      {:ok, report}
    else
      {:error, :missing_expected_output, %{report | missing_expected_output: missing}}
    end
  end

  defp expected_output_missing(metrics, expected_output) do
    []
    |> maybe_missing_minimum(
      expected_output_value(expected_output, :min_agent_output_chars),
      metrics.text_char_count,
      :min_agent_output_chars
    )
    |> maybe_missing_minimum(
      expected_output_value(expected_output, :min_agent_message_chunks),
      metrics.message_chunk_count,
      :min_agent_message_chunks
    )
  end

  defp expected_output_value(expected_output, key) do
    Map.get(expected_output, key) || Map.get(expected_output, to_string(key))
  end

  defp maybe_missing_minimum(missing, nil, _actual, _metric), do: missing

  defp maybe_missing_minimum(missing, expected, actual, _metric) when actual >= expected,
    do: missing

  defp maybe_missing_minimum(missing, expected, actual, metric) do
    [%{metric: metric, expected: expected, actual: actual} | missing]
  end

  defp event_field_present?(events, %{event: event_type, field: field, value: expected}) do
    Enum.any?(events, fn event ->
      event.type == event_type and to_string(get_in(event.payload, field) || "") == expected
    end)
  end

  defp validate_real_agent(result, false), do: result

  defp validate_real_agent({:error, reason, report}, true) do
    reasons = real_agent_rejection_reasons(report)

    if reasons == [] do
      {:error, reason, Map.put(report, :real_agent_evidence, %{required: true, accepted: true})}
    else
      {:error, :real_agent_required,
       report
       |> Map.put(:real_agent_evidence, %{required: true, accepted: false, reasons: reasons})
       |> Map.update(:errors, %{"real_agent" => reasons}, fn errors ->
         Map.put(errors, "real_agent", reasons)
       end)}
    end
  end

  defp validate_real_agent({:ok, report}, true) do
    reasons = real_agent_rejection_reasons(report)

    if reasons == [] do
      {:ok, Map.put(report, :real_agent_evidence, %{required: true, accepted: true})}
    else
      {:error, :real_agent_required,
       report
       |> Map.put(:real_agent_evidence, %{required: true, accepted: false, reasons: reasons})
       |> Map.update(:errors, %{"real_agent" => reasons}, fn errors ->
         Map.put(errors, "real_agent", reasons)
       end)}
    end
  end

  defp real_agent_rejection_reasons(report) do
    process_reasons =
      report.events
      |> Enum.filter(&(&1.type == "agent_process_started"))
      |> Enum.flat_map(fn event ->
        real_agent_rejection_reasons(report.agent, event.payload["args"] || [])
      end)
      |> Enum.uniq()

    []
    |> maybe_reject(report.agent == "stub-acp", "agent is built-in stub-acp")
    |> Kernel.++(process_reasons)
    |> Enum.uniq()
  end

  defp maybe_reject(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reject(reasons, false, _reason), do: reasons

  defp real_agent_rejection_reasons(agent, args) when is_list(args) do
    []
    |> maybe_reject(agent == "stub-acp", "agent is built-in stub-acp")
    |> maybe_reject(test_harness_args?(args), "agent command uses a local test harness")
  end

  defp real_agent_rejection_reasons(agent, _args),
    do: real_agent_rejection_reasons(agent, [])

  defp test_harness_args?(args) do
    Enum.any?(
      args,
      &(&1 in [
          "priv/agent_stub.exs",
          "priv/malformed_agent.exs",
          "test/support/fake_agent_runner.exs"
        ])
    )
  end

  defp event_report(event) do
    %{
      seq: event.seq,
      type: event.type,
      payload: event.payload
    }
  end

  defp agent_output_metrics(events) do
    chunks =
      events
      |> Enum.filter(&(&1.type == "agent_message_chunk"))
      |> Enum.map(&get_in(&1.payload, ["text"]))
      |> Enum.filter(&is_binary/1)

    %{
      message_chunk_count: length(chunks),
      text_char_count: chunks |> Enum.join() |> String.length()
    }
  end

  defp event_field_report(%{event: event, field: field, value: value}) do
    %{
      event: event,
      field: Enum.join(field, "."),
      value: value
    }
  end

  defp expected_output(opts) do
    %{}
    |> maybe_put_expected_output(
      :min_agent_output_chars,
      Keyword.get(opts, :expect_min_agent_output_chars)
    )
    |> maybe_put_expected_output(
      :min_agent_message_chunks,
      Keyword.get(opts, :expect_min_agent_message_chunks)
    )
  end

  defp maybe_put_expected_output(expected, _key, nil), do: expected
  defp maybe_put_expected_output(expected, key, value), do: Map.put(expected, key, value)

  defp expected_output_report(expected_output) do
    expected_output
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp apply_redactions(report, []), do: Map.put(report, :redactions, [])

  defp apply_redactions(report, redactions) do
    redaction_values = Enum.map(redactions, & &1.value)

    report
    |> redact_value(redaction_values)
    |> Map.put(:redactions, Enum.map(redactions, &redaction_report/1))
  end

  defp redact_value(value, redactions) when is_binary(value) do
    Enum.reduce(redactions, value, fn redaction, text ->
      String.replace(text, redaction, "[REDACTED]")
    end)
  end

  defp redact_value(value, redactions) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {key, redact_value(item, redactions)} end)
    |> Map.new()
  end

  defp redact_value(value, redactions) when is_list(value) do
    Enum.map(value, &redact_value(&1, redactions))
  end

  defp redact_value(value, _redactions), do: value

  defp redaction_report(%{source: :literal}), do: %{source: "literal"}
  defp redaction_report(%{source: :env, name: name}), do: %{source: "env", name: name}

  defp changeset_errors(nil), do: %{}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
