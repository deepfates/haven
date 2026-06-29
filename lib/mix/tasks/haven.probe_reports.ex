defmodule Mix.Tasks.Haven.ProbeReports do
  @moduledoc """
  Validates committed agent probe report artifacts.

      mix haven.probe_reports
      mix haven.probe_reports --path docs/probes/my-agent.json

  By default this checks every `docs/probes/*.json` report. The task is meant
  to guard the production-grade real-agent evidence contract in
  `docs/probes/README.md`.
  """

  use Mix.Task

  @shortdoc "Validates committed Haven agent probe report JSON"

  @switches [path: :keep]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, switches: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    paths = report_paths(opts)

    case validate_paths(paths) do
      :ok ->
        Mix.shell().info("Validated #{length(paths)} probe report(s).")

      {:error, failures} ->
        Enum.each(failures, fn {path, errors} ->
          Mix.shell().error("#{path}:")
          Enum.each(errors, &Mix.shell().error("  - #{&1}"))
        end)

        Mix.raise("Probe report validation failed")
    end
  end

  defp report_paths(opts) do
    case Keyword.get_values(opts, :path) do
      [] ->
        "docs/probes/*.json"
        |> Path.wildcard()
        |> Enum.sort()

      paths ->
        Enum.map(paths, &Path.expand/1)
    end
  end

  defp validate_paths(paths) do
    failures =
      paths
      |> Enum.map(fn path -> {path, Haven.AgentProbeReport.validate_file(path)} end)
      |> Enum.filter(fn
        {_path, :ok} -> false
        {_path, {:error, _errors}} -> true
      end)
      |> Enum.map(fn {path, {:error, errors}} -> {path, errors} end)

    if failures == [], do: :ok, else: {:error, failures}
  end
end
