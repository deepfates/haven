defmodule Mix.Tasks.Haven.AgentProbe do
  @moduledoc """
  Probes a configured ACP agent through Haven's real run lifecycle.

      mix haven.agent_probe --agent stub-acp --workspace . --prompt "hello"
      mix haven.agent_probe --agent my-agent --workspace . --prompt "read README.md" --expect-event file_read_succeeded
      mix haven.agent_probe --agent my-agent --workspace . --prompt "read README.md" --expect-event-field file_read_succeeded:path=README.md
      mix haven.agent_probe --agent my-agent --workspace . --prompt "run tests" --terminal-create-policy deny --expect-event terminal_create_denied
      mix haven.agent_probe --agent my-agent --workspace . --prompt "run tests" --report docs/probes/my-agent.json
      mix haven.agent_probe --agent my-agent --workspace . --prompt "read README.md" --report docs/probes/my-agent-file-read.json --failure-report docs/probe-failures/my-agent-file-mediated-negative.json
      mix haven.agent_probe --agent my-agent --workspace . --prompt "summarize this repo" --load-runs 3 --load-concurrency 2 --require-real-agent --report docs/probe-load/my-agent-load.json
      mix haven.agent_probe --agent my-agent --workspace . --prompt "write a long summary" --expect-min-agent-output-chars 2000 --expect-min-agent-message-chunks 5 --require-real-agent --report docs/probes/my-agent-long-output.json
      mix haven.agent_probe --list-agents --workspace .
      mix haven.agent_probe --list-agents --preflight --workspace .
      mix haven.agent_probe --list-agents --proof-commands --workspace .
      mix haven.agent_probe --list-agents --registry --workspace .
      mix haven.agent_probe --save-registry-agent codex-acp --workspace .

  Use `--list-agents` to inspect configured agent commands, whether they
  resolve on this machine, and whether they are eligible for
  `--require-real-agent` evidence.
  Add `--preflight` to `--list-agents` to try ACP initialization/session
  creation for each eligible probe candidate before attempting a full report.
  Add `--proof-commands` to `--list-agents` to print the basic, file, terminal,
  and policy-guard probe commands for each candidate.
  Add `--registry` to `--list-agents` to show npx-backed ACP agent suggestions
  from the public ACP registry.
  Use `--save-registry-agent AGENT_ID` to persist one public registry suggestion
  into Haven's Agent Setup table, then run `--list-agents --preflight` before
  treating it as evidence.
  Use `--resolve-permissions allow` or `--resolve-permissions deny` when the
  probe prompt is expected to trigger permission-gated file or terminal work.
  Use `--file-read-policy`, `--file-write-policy`, and
  `--terminal-create-policy` to create the probed run with explicit capability
  policy. Use comma-separated `--file-read-paths` or `--file-write-paths` to
  narrow file capability policy to specific workspace-relative paths.
  Use repeated `--expect-event` flags to make the probe fail unless the run
  produces the event types required by the acceptance story.
  Use repeated `--expect-event-field EVENT:payload.path=value` flags to make
  the probe fail unless at least one matching event has that payload value.
  Use `--expect-min-agent-output-chars N` and
  `--expect-min-agent-message-chunks N` to require a minimum streamed agent
  response size.
  Use `--require-real-agent` for evidence intended to satisfy the production-grade
  real-agent validation milestone; it rejects the built-in stub and known test
  harnesses.
  Use repeated `--redact value` or `--redact-env ENV_VAR` flags to replace
  sensitive strings in the printed and written report with `[REDACTED]`.
  Use `--report path.json` to write the full probe report as pretty JSON.
  Use `--failure-report path.json` with `--report` when a failed capability
  proof should be preserved as named negative boundary evidence instead of
  overwriting the positive evidence path.
  Terminal output is summary-first by default. Add `--show-events` to print
  every persisted event payload in the terminal as well as in the report file.
  By default, the task suppresses debug-level application logs so preflight and
  probe output remains readable as evidence. Add `--verbose` to keep the
  current logger level while debugging the task itself.
  Use `--load-runs N` with `--report` to write an aggregate report proving N
  separate durable runs completed through the same configured agent path.
  Use `--load-concurrency N` with `--load-runs` to run up to N child probes at
  the same time.
  """

  use Mix.Task

  @shortdoc "Runs an end-to-end Haven probe against a configured ACP agent"
  @requirements ["app.start"]

  @switches [
    agent: :string,
    workspace: :string,
    prompt: :string,
    timeout: :integer,
    load_runs: :integer,
    load_concurrency: :integer,
    expect_min_agent_output_chars: :integer,
    expect_min_agent_message_chunks: :integer,
    resolve_permissions: :string,
    expect_event: :keep,
    expect_event_field: :keep,
    report: :string,
    failure_report: :string,
    title: :string,
    file_read_policy: :string,
    file_read_paths: :string,
    file_write_policy: :string,
    file_write_paths: :string,
    terminal_create_policy: :string,
    redact: :keep,
    redact_env: :keep,
    require_real_agent: :boolean,
    list_agents: :boolean,
    preflight: :boolean,
    proof_commands: :boolean,
    registry: :boolean,
    save_registry_agent: :string,
    verbose: :boolean,
    show_events: :boolean
  ]

  @aliases [a: :agent, w: :workspace, p: :prompt, t: :timeout]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    opts = normalize_opts(opts)
    report_path = Keyword.get(opts, :report)
    failure_report_path = Keyword.get(opts, :failure_report)

    with_probe_log_level(opts, fn ->
      cond do
        agent_id = Keyword.get(opts, :save_registry_agent) ->
          save_registry_agent!(agent_id, Keyword.fetch!(opts, :workspace))

        Keyword.get(opts, :list_agents, false) ->
          print_agent_inventory(
            Keyword.fetch!(opts, :workspace),
            Keyword.get(opts, :preflight, false),
            Keyword.get(opts, :proof_commands, false),
            Keyword.get(opts, :timeout, 5_000),
            Keyword.get(opts, :registry, false)
          )

        true ->
          case run_probe(opts) do
            {:ok, report} ->
              print_any_report(report, Keyword.get(opts, :show_events, false))
              write_report(report, report_path)

            {:error, reason, report} ->
              print_any_report(report, Keyword.get(opts, :show_events, false))
              write_report(report, failure_report_path || report_path)
              Mix.raise("Agent probe failed: #{reason}")
          end
      end
    end)
  end

  defp with_probe_log_level(opts, fun) do
    if Keyword.get(opts, :verbose, false) do
      fun.()
    else
      previous_level = Logger.level()
      Logger.configure(level: :info)

      try do
        fun.()
      after
        Logger.configure(level: previous_level)
      end
    end
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.update(:workspace, File.cwd!(), &Path.expand/1)
    |> Keyword.update(:report, nil, &Path.expand/1)
    |> Keyword.update(:failure_report, nil, &Path.expand/1)
    |> normalize_load_runs()
    |> normalize_load_concurrency()
    |> normalize_positive_integer(:expect_min_agent_output_chars)
    |> normalize_positive_integer(:expect_min_agent_message_chunks)
    |> Keyword.update(:resolve_permissions, nil, &normalize_permission_resolution/1)
    |> normalize_path_scope(:file_read_paths)
    |> normalize_path_scope(:file_write_paths)
    |> normalize_capability_policy(:file_read_policy, ["ask", "allow", "deny"])
    |> normalize_capability_policy(:file_write_policy, ["ask", "allow", "deny"])
    |> normalize_capability_policy(:terminal_create_policy, ["ask", "allow", "deny"])
  end

  defp normalize_permission_resolution(nil), do: nil
  defp normalize_permission_resolution("none"), do: nil
  defp normalize_permission_resolution(option_id), do: option_id

  defp normalize_load_runs(opts) do
    case Keyword.fetch(opts, :load_runs) do
      {:ok, count} when is_integer(count) and count >= 2 ->
        opts

      {:ok, count} ->
        Mix.raise("Invalid --load-runs #{inspect(count)}; expected an integer >= 2")

      :error ->
        opts
    end
  end

  defp normalize_load_concurrency(opts) do
    case {Keyword.fetch(opts, :load_concurrency), Keyword.fetch(opts, :load_runs)} do
      {{:ok, concurrency}, {:ok, count}}
      when is_integer(concurrency) and concurrency >= 1 and concurrency <= count ->
        opts

      {{:ok, concurrency}, {:ok, count}} ->
        Mix.raise(
          "Invalid --load-concurrency #{inspect(concurrency)}; expected an integer between 1 and #{count}"
        )

      {{:ok, _concurrency}, :error} ->
        Mix.raise("--load-concurrency requires --load-runs")

      {:error, _load_runs} ->
        opts
    end
  end

  defp normalize_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 1 ->
        opts

      {:ok, value} ->
        Mix.raise(
          "Invalid --#{String.replace(to_string(key), "_", "-")} #{inspect(value)}; expected an integer >= 1"
        )

      :error ->
        opts
    end
  end

  defp normalize_path_scope(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(opts, key, parse_path_scope(value))
      :error -> opts
    end
  end

  defp parse_path_scope(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_capability_policy(opts, key, allowed) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if value in allowed do
          opts
        else
          Mix.raise(
            "Invalid --#{String.replace(to_string(key), "_", "-")} #{inspect(value)}; expected one of #{Enum.join(allowed, ", ")}"
          )
        end

      :error ->
        opts
    end
  end

  defp print_agent_inventory(workspace, preflight?, proof_commands?, preflight_timeout, registry?) do
    inventory = Haven.AgentProbe.agent_inventory(workspace)

    Mix.shell().info("Workspace: #{workspace}")
    Mix.shell().info("")
    Mix.shell().info("Configured agents:")

    preflight_results =
      Enum.reduce(inventory, [], fn agent, results ->
        Mix.shell().info("- #{agent.agent}: #{agent.status}")

        if agent.status == "ready" do
          Mix.shell().info("  executable: #{agent.executable}")
          Mix.shell().info("  args: #{inspect_args(agent.args)}")
          Mix.shell().info("  cwd: #{agent.cwd || "(inherit)"}")
          Mix.shell().info("  env keys: #{Enum.join(agent.env_keys, ", ")}")
        else
          Mix.shell().info("  error: #{agent.error}")
        end

        Mix.shell().info("  static real-agent probe candidate: #{agent.real_agent_candidate}")

        if agent.real_agent_rejection_reasons != [] do
          Mix.shell().info(
            "  rejection reasons: #{Enum.join(agent.real_agent_rejection_reasons, "; ")}"
          )
        else
          Mix.shell().info(
            "  evidence status: command resolves, but ACP compatibility is not proven until preflight or a full probe passes"
          )
        end

        if agent.real_agent_candidate do
          if proof_commands? do
            print_agent_proof_commands(agent.agent, workspace)
          else
            Mix.shell().info(
              "  proof commands: hidden (add --proof-commands to print basic/file/terminal acceptance commands)"
            )
          end

          if preflight? do
            [print_agent_preflight(agent.agent, workspace, preflight_timeout) | results]
          else
            Mix.shell().info(
              "  preflight: not run (add --preflight to verify ACP initialize/session handshake before treating this as evidence)"
            )

            results
          end
        else
          results
        end
      end)

    Mix.shell().info("")

    case Enum.filter(inventory, & &1.real_agent_candidate) do
      [] ->
        Mix.shell().info(
          "Static real-agent probe candidates: none. Configure an ACP-speaking non-test agent before generating docs/probes evidence."
        )

      candidates ->
        Mix.shell().info(
          "Static real-agent probe candidates: #{Enum.map_join(candidates, ", ", & &1.agent)}"
        )
    end

    if preflight? do
      print_preflight_summary(Enum.reverse(preflight_results))
    end

    if registry? do
      print_registry_suggestions(workspace)
    end
  end

  defp inspect_args(args) when length(args) > 12 do
    shown = Enum.take(args, 12)
    inspect(shown ++ ["... #{length(args) - length(shown)} more"])
  end

  defp inspect_args(args), do: inspect(args)

  defp print_agent_proof_commands(agent, workspace) do
    Mix.shell().info("  proof commands:")

    Enum.each(agent_proof_commands(agent, workspace), fn {label, command} ->
      Mix.shell().info("    #{label}: #{command}")
    end)
  end

  defp agent_proof_commands(agent, workspace) do
    [
      {"basic",
       probe_command(agent, workspace, [
         "--expect-event",
         "agent_initialized",
         "--expect-event",
         "agent_session_started",
         "--expect-event",
         "turn_finished",
         "--report",
         "docs/probes/#{agent}-basic.json"
       ])},
      {"file-read",
       probe_command(agent, workspace, [
         "--prompt",
         "read README.md through the client file-read capability",
         "--file-read-policy",
         "allow",
         "--file-read-paths",
         "README.md,docs",
         "--expect-event",
         "file_read_requested",
         "--expect-event",
         "capability_policy_applied",
         "--expect-event",
         "file_read_succeeded",
         "--expect-event",
         "turn_finished",
         "--expect-event-field",
         "file_read_requested:payload.path=README.md",
         "--expect-event-field",
         "file_read_succeeded:payload.path=README.md",
         "--report",
         "docs/probes/#{agent}-file-read.json",
         "--failure-report",
         "docs/probe-failures/#{agent}-file-mediated-negative.json"
       ])},
      {"file-write-approval",
       probe_command(agent, workspace, [
         "--prompt",
         "write Haven probe sentinel to notes/haven-probe.txt through the client file-write capability",
         "--file-write-policy",
         "ask",
         "--file-write-paths",
         "notes",
         "--resolve-permissions",
         "allow",
         "--expect-event",
         "file_write_requested",
         "--expect-event",
         "permission_requested",
         "--expect-event",
         "permission_resolved",
         "--expect-event",
         "file_write_succeeded",
         "--expect-event",
         "turn_finished",
         "--expect-event-field",
         "file_write_requested:payload.path=notes/haven-probe.txt",
         "--expect-event-field",
         "file_write_succeeded:payload.path=notes/haven-probe.txt",
         "--report",
         "docs/probes/#{agent}-file-write-approval.json",
         "--failure-report",
         "docs/probe-failures/#{agent}-file-write-mediated-negative.json"
       ])},
      {"terminal-approval",
       probe_command(agent, workspace, [
         "--prompt",
         "run mix --version through the client terminal capability",
         "--terminal-create-policy",
         "ask",
         "--resolve-permissions",
         "allow",
         "--expect-event",
         "terminal_create_requested",
         "--expect-event",
         "permission_requested",
         "--expect-event",
         "permission_resolved",
         "--expect-event",
         "terminal_created",
         "--expect-event",
         "terminal_output_succeeded",
         "--expect-event",
         "terminal_released",
         "--expect-event",
         "turn_finished",
         "--expect-event-field",
         "terminal_create_requested:payload.command=mix",
         "--expect-event-field",
         "terminal_output_succeeded:payload.exit_status=0",
         "--report",
         "docs/probes/#{agent}-terminal-approval.json",
         "--failure-report",
         "docs/probe-failures/#{agent}-terminal-mediated-negative.json"
       ])},
      {"terminal-denied",
       probe_command(agent, workspace, [
         "--prompt",
         "try to open a terminal",
         "--terminal-create-policy",
         "deny",
         "--expect-event",
         "terminal_create_requested",
         "--expect-event",
         "capability_policy_applied",
         "--expect-event",
         "terminal_create_denied",
         "--expect-event",
         "turn_finished",
         "--expect-event-field",
         "terminal_create_requested:payload.command=mix",
         "--expect-event-field",
         "capability_policy_applied:payload.decision=deny",
         "--report",
         "docs/probes/#{agent}-terminal-denied.json",
         "--failure-report",
         "docs/probe-failures/#{agent}-terminal-denied-mediated-negative.json"
       ])}
    ]
  end

  defp probe_command(agent, workspace, args) do
    [
      "mix",
      "haven.agent_probe",
      "--agent",
      agent,
      "--workspace",
      workspace,
      "--require-real-agent"
      | args
    ]
    |> Enum.map_join(" ", &shell_arg/1)
  end

  defp print_agent_preflight(agent, workspace, timeout) do
    case Haven.AgentProbe.preflight(
           agent: agent,
           workspace: workspace,
           timeout: timeout,
           require_real_agent: true
         ) do
      {:ok, report} ->
        Mix.shell().info("  preflight: ok (run #{report.run_id}, status #{report.status})")
        %{agent: agent, status: :ok, run_id: report.run_id}

      {:error, reason, report} ->
        Mix.shell().info("  preflight: failed (#{reason}, run #{report.run_id || "none"})")

        report.events
        |> List.last()
        |> case do
          nil ->
            :ok

          event ->
            Mix.shell().info(
              "  preflight last event: #{event.type} #{Jason.encode!(event.payload)}"
            )
        end

        %{agent: agent, status: :failed, run_id: report.run_id, reason: reason}
    end
  end

  defp print_preflight_summary([]) do
    Mix.shell().info("Preflight summary: no static real-agent probe candidates.")
  end

  defp print_preflight_summary(results) do
    ok = Enum.filter(results, &(&1.status == :ok))
    failed = Enum.filter(results, &(&1.status == :failed))

    Mix.shell().info(
      "Preflight summary: #{length(ok)}/#{length(results)} #{pluralize(length(results), "candidate")} passed ACP initialize/session handshake; #{length(failed)} failed."
    )

    if ok != [] do
      Mix.shell().info("Preflight-ready agents: #{Enum.map_join(ok, ", ", & &1.agent)}")
    end
  end

  defp pluralize(1, singular), do: singular
  defp pluralize(_count, singular), do: singular <> "s"

  defp print_registry_suggestions(workspace) do
    Mix.shell().info("")
    Mix.shell().info("ACP registry npx suggestions:")

    Mix.shell().info(
      "  warning: registry commands download and run third-party code; preflight or probe them only with an approved workspace and auth scope"
    )

    case Haven.AgentRegistry.fetch_suggestions() do
      {:ok, []} ->
        Mix.shell().info("  none found")

      {:ok, suggestions} ->
        npx_status =
          case System.find_executable("npx") do
            nil -> "missing"
            path -> path
          end

        Mix.shell().info("  npx: #{npx_status}")

        suggestions
        |> Enum.take(12)
        |> Enum.each(fn suggestion ->
          Mix.shell().info(
            "  - #{suggestion.id} (#{suggestion.name} #{suggestion.version || "unknown"})"
          )

          Mix.shell().info("    package: #{suggestion.package}")
          Mix.shell().info("    env keys: #{registry_env_keys(suggestion)}")
          Mix.shell().info("    try: #{Haven.AgentRegistry.trial_command(suggestion, workspace)}")
        end)

        if length(suggestions) > 12 do
          Mix.shell().info("  ... #{length(suggestions) - 12} more npx registry entries")
        end

      {:error, reason} ->
        Mix.shell().info("  registry unavailable: #{inspect(reason)}")
    end
  end

  defp registry_env_keys(suggestion) do
    case Haven.AgentRegistry.env_keys(suggestion) do
      [] -> "none"
      keys -> Enum.join(keys, ", ")
    end
  end

  defp save_registry_agent!(agent_id, workspace) do
    case Haven.AgentRegistry.fetch_suggestions() do
      {:ok, suggestions} ->
        case Enum.find(suggestions, &(&1.id == agent_id)) do
          nil ->
            Mix.raise("Registry agent #{inspect(agent_id)} was not found")

          suggestion ->
            case Haven.Agents.upsert_agent_config_from_registry_suggestion(suggestion) do
              {:ok, agent_config} ->
                Mix.shell().info(
                  "Saved registry agent #{agent_config.key}: #{agent_config.executable} #{inspect_args(Map.get(agent_config.args || %{}, "items", []))}"
                )

                Mix.shell().info(
                  "Next: mix haven.agent_probe --list-agents --preflight --workspace #{shell_arg(workspace)}"
                )

              {:error, changeset} ->
                Mix.raise(
                  "Could not save registry agent #{inspect(agent_id)}: #{inspect(changeset.errors)}"
                )
            end
        end

      {:error, reason} ->
        Mix.raise("Registry unavailable: #{inspect(reason)}")
    end
  end

  defp shell_arg(value) do
    value = to_string(value)

    if String.match?(value, ~r/^[A-Za-z0-9_.,:\/=@+-]+$/) do
      value
    else
      "'#{String.replace(value, "'", "'\"'\"'")}'"
    end
  end

  defp run_probe(opts) do
    case Keyword.fetch(opts, :load_runs) do
      {:ok, _count} -> Haven.AgentProbe.run_load(opts)
      :error -> Haven.AgentProbe.run(opts)
    end
  end

  defp print_any_report(%{kind: "agent_probe_load"} = report, show_events?),
    do: print_load_report(report, show_events?)

  defp print_any_report(report, show_events?), do: print_report(report, show_events?)

  defp print_load_report(report, show_events?) do
    Mix.shell().info("Load probe: #{report.run_count} run(s)")
    Mix.shell().info("Concurrency: #{Map.get(report, :concurrency, 1)}")
    Mix.shell().info("Agent: #{report.agent}")
    Mix.shell().info("Workspace: #{report.workspace}")
    Mix.shell().info("Status: #{report.status}")
    Mix.shell().info("Prompt: #{report.prompt}")

    if report.expected_events != [] do
      Mix.shell().info("Expected events: #{Enum.join(report.expected_events, ", ")}")
    end

    print_output_expectations(report)
    print_load_summary(report)

    Mix.shell().info("")
    Mix.shell().info("Runs:")

    Enum.each(report.reports, fn child ->
      Mix.shell().info(
        "- #{child.run_id || "(not created)"}: #{child.status} (#{length(child.events)} events)"
      )

      if show_events? do
        print_event_lines(child.events, "  ")
      end
    end)

    if report.failures != [] do
      Mix.shell().info("")
      Mix.shell().info("Failures:")

      Enum.each(report.failures, fn failure ->
        Mix.shell().info(
          "- #{failure.index}: #{failure.reason} #{failure.run_id || "(not created)"}"
        )
      end)
    end
  end

  defp print_load_summary(report) do
    status_counts =
      report.reports
      |> Enum.map(& &1.status)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {status, _count} -> status end)

    event_counts =
      report.reports
      |> Enum.flat_map(& &1.events)
      |> Enum.map(& &1.type)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {type, _count} -> type end)

    Mix.shell().info("")
    Mix.shell().info("Run summary: #{format_counts(status_counts)}")
    Mix.shell().info("Child event summary: #{format_counts(event_counts)}")
    Mix.shell().info("Use --show-events to print full child event payloads.")
  end

  defp print_report(report, show_events?) do
    Mix.shell().info("Run: #{report.run_id || "(not created)"}")
    Mix.shell().info("Agent: #{report.agent}")
    Mix.shell().info("Workspace: #{report.workspace}")
    Mix.shell().info("Status: #{report.status}")
    Mix.shell().info("Prompt: #{report.prompt}")

    if report.expected_events != [] do
      Mix.shell().info("Expected events: #{Enum.join(report.expected_events, ", ")}")
    end

    print_output_expectations(report)

    if Map.get(report, :expected_event_fields, []) != [] do
      Mix.shell().info(
        "Expected event fields: #{Enum.map_join(report.expected_event_fields, ", ", &event_field_label/1)}"
      )
    end

    if report.missing_expected_events != [] do
      Mix.shell().info(
        "Missing expected events: #{Enum.join(report.missing_expected_events, ", ")}"
      )
    end

    if Map.get(report, :missing_expected_event_fields, []) != [] do
      Mix.shell().info(
        "Missing expected event fields: #{Enum.map_join(report.missing_expected_event_fields, ", ", &event_field_label/1)}"
      )
    end

    if Map.get(report, :missing_expected_output, []) != [] do
      Mix.shell().info(
        "Missing expected output: #{Enum.map_join(report.missing_expected_output, ", ", &output_gap_label/1)}"
      )
    end

    if Map.get(report, :unsupported_client_capabilities, []) != [] do
      Mix.shell().info("")
      Mix.shell().info("Unsupported mediated capabilities:")

      Enum.each(report.unsupported_client_capabilities, fn capability ->
        Mix.shell().info("- #{unsupported_capability_label(capability)}")
      end)
    end

    if Map.get(report, :diagnostics, []) != [] do
      Mix.shell().info("")
      Mix.shell().info("Diagnostics:")

      Enum.each(report.diagnostics, fn diagnostic ->
        Mix.shell().info("- #{diagnostic.message}")
      end)
    end

    print_event_summary(report.events, show_events?)

    if Map.get(report, :errors) not in [nil, %{}] do
      Mix.shell().info("")
      Mix.shell().info("Errors: #{inspect(report.errors)}")
    end
  end

  defp print_event_summary(events, true) do
    Mix.shell().info("")
    Mix.shell().info("Events:")
    print_event_lines(events, "")
  end

  defp print_event_summary(events, false) do
    event_counts =
      events
      |> Enum.map(& &1.type)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {type, _count} -> type end)

    Mix.shell().info("")
    Mix.shell().info("Event summary: #{length(events)} event(s)")

    Mix.shell().info(
      "Event types: #{Enum.map_join(event_counts, ", ", fn {type, count} -> "#{type}=#{count}" end)}"
    )

    Mix.shell().info("Use --show-events to print full event payloads.")
  end

  defp format_counts([]), do: "none"

  defp format_counts(counts) do
    Enum.map_join(counts, ", ", fn {label, count} -> "#{label}=#{count}" end)
  end

  defp print_event_lines(events, prefix) do
    Enum.each(events, fn event ->
      Mix.shell().info("#{prefix}#{event.seq}. #{event.type} #{Jason.encode!(event.payload)}")
    end)
  end

  defp write_report(_report, nil), do: :ok

  defp write_report(report, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(report, pretty: true))
    Mix.shell().info("")
    Mix.shell().info("Report written: #{path}")
  end

  defp event_field_label(%{event: event, field: field, value: value}) do
    "#{event}:#{field}=#{value}"
  end

  defp event_field_label(%{"event" => event, "field" => field, "value" => value}) do
    "#{event}:#{field}=#{value}"
  end

  defp print_output_expectations(report) do
    metrics = Map.get(report, :agent_output_metrics, %{})
    expected = Map.get(report, :expected_output, %{})

    if expected != %{} do
      Mix.shell().info(
        "Agent output: #{Map.get(metrics, :text_char_count, 0)} chars across #{Map.get(metrics, :message_chunk_count, 0)} chunks"
      )

      Mix.shell().info(
        "Expected output: #{Enum.map_join(expected, ", ", fn {key, value} -> "#{key}>=#{value}" end)}"
      )
    end
  end

  defp output_gap_label(%{metric: metric, expected: expected, actual: actual}) do
    "#{metric} expected >= #{expected}, got #{actual}"
  end

  defp output_gap_label(%{"metric" => metric, "expected" => expected, "actual" => actual}) do
    "#{metric} expected >= #{expected}, got #{actual}"
  end

  defp unsupported_capability_label(%{
         capability: capability,
         missing_events: missing_events,
         observed_events: observed_events
       }) do
    "#{capability}: missing #{Enum.join(missing_events, ", ")}; observed #{Enum.join(observed_events, ", ")}"
  end

  defp unsupported_capability_label(%{
         "capability" => capability,
         "missing_events" => missing_events,
         "observed_events" => observed_events
       }) do
    "#{capability}: missing #{Enum.join(missing_events, ", ")}; observed #{Enum.join(observed_events, ", ")}"
  end
end
