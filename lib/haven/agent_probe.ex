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
      |> redacted_report(prompt, expected_events, expected_event_fields, redactions)
      |> validate_expected_events(expected_events)
      |> validate_expected_event_fields(expected_event_fields)
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

  @spec agent_inventory(String.t()) :: [map()]
  def agent_inventory(workspace \\ File.cwd!()) do
    workspace = Path.expand(workspace)

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

        {:error, reason} ->
          %{
            agent: agent,
            status: "invalid",
            error: inspect(reason),
            real_agent_candidate: false,
            real_agent_rejection_reasons: ["agent command cannot be resolved"]
          }
      end
    end)
  end

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

  defp report(run, prompt, expected_events, expected_event_fields) do
    %{
      run_id: run.id,
      agent: run.agent,
      workspace: run.workspace,
      status: run.status,
      prompt: prompt,
      events: Enum.map(Events.list_for_run(run.id), &event_report/1),
      expected_events: expected_events,
      missing_expected_events: [],
      diagnostics: [],
      expected_event_fields: Enum.map(expected_event_fields, &event_field_report/1),
      missing_expected_event_fields: []
    }
  end

  defp redacted_report(run, prompt, expected_events, expected_event_fields, redactions) do
    run
    |> report(prompt, expected_events, expected_event_fields)
    |> apply_redactions(redactions)
  end

  defp invalid_run_report(
         agent,
         workspace,
         prompt,
         changeset,
         expected_events,
         expected_event_fields
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
      missing_expected_event_fields: Enum.map(expected_event_fields, &event_field_report/1)
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

  defp observed_tool_events(events) do
    events
    |> Enum.map(& &1.type)
    |> Enum.filter(&(&1 in ["tool_call", "tool_call_update"]))
    |> Enum.uniq()
  end

  defp client_capability_event?(type) do
    String.starts_with?(type, "file_") or String.starts_with?(type, "terminal_")
  end

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

  defp event_field_present?(events, %{event: event_type, field: field, value: expected}) do
    Enum.any?(events, fn event ->
      event.type == event_type and to_string(get_in(event.payload, field) || "") == expected
    end)
  end

  defp validate_real_agent({:error, reason, report}, _require_real_agent?),
    do: {:error, reason, report}

  defp validate_real_agent({:ok, report}, false), do: {:ok, report}

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

  defp event_field_report(%{event: event, field: field, value: value}) do
    %{
      event: event,
      field: Enum.join(field, "."),
      value: value
    }
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
