defmodule Mix.Tasks.Haven.ProbeReports do
  @moduledoc """
  Validates committed agent probe report artifacts.

      mix haven.probe_reports
      mix haven.probe_reports --path docs/probes/my-agent.json
      mix haven.probe_reports --failure-path docs/probe-failures/my-agent-negative.json

  By default this checks every `docs/probes/*.json` positive report and every
  `docs/probe-failures/*.json` negative boundary report. The task is meant to
  guard the production-grade real-agent evidence contracts in `docs/probes` and
  `docs/probe-failures`.
  """

  use Mix.Task

  @shortdoc "Validates committed Haven agent probe report JSON"

  @switches [path: :keep, failure_path: :keep]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, switches: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    paths = report_paths(opts)
    failure_paths = failure_report_paths(opts)

    case validate_all(paths, failure_paths) do
      :ok ->
        Mix.shell().info(
          "Validated #{length(paths)} probe report(s) and #{length(failure_paths)} probe failure report(s)."
        )

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

  defp failure_report_paths(opts) do
    case Keyword.get_values(opts, :failure_path) do
      [] ->
        if Keyword.get_values(opts, :path) == [] do
          "docs/probe-failures/*.json"
          |> Path.wildcard()
          |> Enum.sort()
        else
          []
        end

      paths ->
        Enum.map(paths, &Path.expand/1)
    end
  end

  defp validate_all(paths, failure_paths) do
    failures =
      positive_failures(paths) ++ negative_failures(failure_paths)

    if failures == [], do: :ok, else: {:error, failures}
  end

  defp positive_failures(paths) do
    failures =
      paths
      |> Enum.map(fn path -> {path, Haven.AgentProbeReport.validate_file(path)} end)
      |> Enum.filter(fn
        {_path, :ok} -> false
        {_path, {:error, _errors}} -> true
      end)
      |> Enum.map(fn {path, {:error, errors}} -> {path, errors} end)

    failures
  end

  defp negative_failures(paths) do
    paths
    |> Enum.map(fn path -> {path, Haven.AgentProbeReport.validate_failure_file(path)} end)
    |> Enum.filter(fn
      {_path, :ok} -> false
      {_path, {:error, _errors}} -> true
    end)
    |> Enum.map(fn {path, {:error, errors}} -> {path, errors} end)
  end
end
