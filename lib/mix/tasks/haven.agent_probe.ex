defmodule Mix.Tasks.Haven.AgentProbe do
  @moduledoc """
  Probes a configured ACP agent through Haven's real run lifecycle.

      mix haven.agent_probe --agent stub-acp --workspace . --prompt "hello"

  Use `--resolve-permissions allow` or `--resolve-permissions deny` when the
  probe prompt is expected to trigger permission-gated file or terminal work.
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
    title: :string
  ]

  @aliases [a: :agent, w: :workspace, p: :prompt, t: :timeout]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    opts = normalize_opts(opts)

    case Haven.AgentProbe.run(opts) do
      {:ok, report} ->
        print_report(report)

      {:error, reason, report} ->
        print_report(report)
        Mix.raise("Agent probe failed: #{reason}")
    end
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.update(:workspace, File.cwd!(), &Path.expand/1)
    |> Keyword.update(:resolve_permissions, nil, &normalize_permission_resolution/1)
  end

  defp normalize_permission_resolution(nil), do: nil
  defp normalize_permission_resolution("none"), do: nil
  defp normalize_permission_resolution(option_id), do: option_id

  defp print_report(report) do
    Mix.shell().info("Run: #{report.run_id || "(not created)"}")
    Mix.shell().info("Agent: #{report.agent}")
    Mix.shell().info("Workspace: #{report.workspace}")
    Mix.shell().info("Status: #{report.status}")
    Mix.shell().info("Prompt: #{report.prompt}")
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
end
