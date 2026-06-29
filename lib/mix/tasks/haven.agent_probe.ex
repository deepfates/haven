defmodule Mix.Tasks.Haven.AgentProbe do
  @moduledoc """
  Probes a configured ACP agent through Haven's real run lifecycle.

      mix haven.agent_probe --agent stub-acp --workspace . --prompt "hello"
      mix haven.agent_probe --agent my-agent --workspace . --prompt "read README.md" --expect-event file_read_succeeded
      mix haven.agent_probe --agent my-agent --workspace . --prompt "run tests" --terminal-create-policy deny --expect-event terminal_create_denied
      mix haven.agent_probe --agent my-agent --workspace . --prompt "run tests" --report docs/probes/my-agent.json

  Use `--resolve-permissions allow` or `--resolve-permissions deny` when the
  probe prompt is expected to trigger permission-gated file or terminal work.
  Use `--file-read-policy`, `--file-write-policy`, and
  `--terminal-create-policy` to create the probed run with explicit capability
  policy.
  Use repeated `--expect-event` flags to make the probe fail unless the run
  produces the event types required by the acceptance story.
  Use `--require-real-agent` for evidence intended to satisfy the real-agent
  Grei validation milestone; it rejects the built-in stub and known test
  harnesses.
  Use repeated `--redact value` or `--redact-env ENV_VAR` flags to replace
  sensitive strings in the printed and written report with `[REDACTED]`.
  Use `--report path.json` to write the full probe report as pretty JSON.
  """

  use Mix.Task

  @shortdoc "Runs an end-to-end Haven probe against a configured ACP agent"
  @requirements ["app.start"]

  @switches [
    agent: :string,
    workspace: :string,
    prompt: :string,
    timeout: :integer,
    resolve_permissions: :string,
    expect_event: :keep,
    report: :string,
    title: :string,
    file_read_policy: :string,
    file_write_policy: :string,
    terminal_create_policy: :string,
    redact: :keep,
    redact_env: :keep,
    require_real_agent: :boolean
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

    case Haven.AgentProbe.run(opts) do
      {:ok, report} ->
        print_report(report)
        write_report(report, report_path)

      {:error, reason, report} ->
        print_report(report)
        write_report(report, report_path)
        Mix.raise("Agent probe failed: #{reason}")
    end
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.update(:workspace, File.cwd!(), &Path.expand/1)
    |> Keyword.update(:report, nil, &Path.expand/1)
    |> Keyword.update(:resolve_permissions, nil, &normalize_permission_resolution/1)
    |> normalize_capability_policy(:file_read_policy, ["ask", "allow", "deny"])
    |> normalize_capability_policy(:file_write_policy, ["ask", "allow", "deny"])
    |> normalize_capability_policy(:terminal_create_policy, ["ask", "allow", "deny"])
  end

  defp normalize_permission_resolution(nil), do: nil
  defp normalize_permission_resolution("none"), do: nil
  defp normalize_permission_resolution(option_id), do: option_id

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

  defp print_report(report) do
    Mix.shell().info("Run: #{report.run_id || "(not created)"}")
    Mix.shell().info("Agent: #{report.agent}")
    Mix.shell().info("Workspace: #{report.workspace}")
    Mix.shell().info("Status: #{report.status}")
    Mix.shell().info("Prompt: #{report.prompt}")

    if report.expected_events != [] do
      Mix.shell().info("Expected events: #{Enum.join(report.expected_events, ", ")}")
    end

    if report.missing_expected_events != [] do
      Mix.shell().info(
        "Missing expected events: #{Enum.join(report.missing_expected_events, ", ")}"
      )
    end

    Mix.shell().info("")
    Mix.shell().info("Events:")

    Enum.each(report.events, fn event ->
      Mix.shell().info("#{event.seq}. #{event.type} #{Jason.encode!(event.payload)}")
    end)

    if Map.get(report, :errors) not in [nil, %{}] do
      Mix.shell().info("")
      Mix.shell().info("Errors: #{inspect(report.errors)}")
    end
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
end
