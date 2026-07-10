defmodule Haven.Agents do
  @moduledoc """
  Resolves run agent identifiers into executable ACP transports.

  `stub-acp` is built in for deterministic local validation. Additional agents
  can be configured with:

      config :haven, :agents, %{
        "my-agent" => %{
          executable: "/path/to/agent",
          args: ["--workspace", "{workspace}"],
          cwd: "{workspace}",
          env: %{"TOKEN" => "...", "WORKSPACE" => "{workspace}"}
        }
      }
  """

  import Bitwise
  import Ecto.Query

  alias Haven.Agents.AgentConfig
  alias Haven.AgentProbeReport
  alias Haven.Repo

  @env_name_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @type command :: %{
          executable: String.t(),
          args: [String.t()],
          cwd: String.t() | nil,
          env: [{String.t(), String.t()}],
          label: String.t()
        }

  @spec available :: [{String.t(), String.t()}]
  def available do
    configured =
      all_configured_agents()
      |> Map.keys()
      |> Enum.reject(&(&1 in ["stub-acp", "cantrip-familiar"]))
      |> Enum.sort()
      |> Enum.map(&{&1, &1})

    [{"stub-acp", "stub-acp"} | cantrip_available() ++ configured]
  end

  def list_agent_configs do
    Repo.all(from agent in AgentConfig, order_by: [asc: agent.key])
  end

  def accepted_probe_reports_by_agent(agent_keys, opts \\ []) when is_list(agent_keys) do
    agent_keys = MapSet.new(agent_keys)

    opts
    |> probe_report_paths()
    |> Enum.flat_map(&accepted_probe_report_summary/1)
    |> Enum.filter(&MapSet.member?(agent_keys, &1.agent))
    |> Enum.group_by(& &1.agent)
  end

  def accepted_probe_reports(agent_key, opts \\ []) when is_binary(agent_key) do
    agent_key
    |> List.wrap()
    |> accepted_probe_reports_by_agent(opts)
    |> Map.get(agent_key, [])
  end

  def capability_gap_reports_by_agent(agent_keys, opts \\ []) when is_list(agent_keys) do
    agent_keys = MapSet.new(agent_keys)

    opts
    |> capability_gap_report_paths()
    |> Enum.flat_map(&capability_gap_report_summary/1)
    |> Enum.filter(&MapSet.member?(agent_keys, &1.agent))
    |> Enum.group_by(& &1.agent)
  end

  def capability_gap_reports(agent_key, opts \\ []) when is_binary(agent_key) do
    agent_key
    |> List.wrap()
    |> capability_gap_reports_by_agent(opts)
    |> Map.get(agent_key, [])
  end

  def create_agent_config(attrs) do
    %AgentConfig{}
    |> AgentConfig.changeset(attrs)
    |> Repo.insert()
  end

  def get_agent_config(id), do: Repo.get(AgentConfig, id)

  def get_agent_config!(id), do: Repo.get!(AgentConfig, id)

  def update_agent_config(%AgentConfig{} = agent_config, attrs) do
    agent_config
    |> AgentConfig.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent_config(%AgentConfig{} = agent_config) do
    Repo.delete(agent_config)
  end

  defp probe_report_paths(opts) do
    opts
    |> Keyword.get(:path, "docs/probes/*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp capability_gap_report_paths(opts) do
    opts
    |> Keyword.get(:path, "docs/probe-failures/*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp accepted_probe_report_summary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, report} <- Jason.decode(content),
         :ok <- AgentProbeReport.validate(report) do
      [
        %{
          agent: report["agent"],
          path: path,
          run_id: report["run_id"],
          status: report["status"],
          prompt: report["prompt"],
          expected_events: report["expected_events"] || [],
          expected_event_fields: report["expected_event_fields"] || []
        }
      ]
    else
      _ -> []
    end
  end

  defp capability_gap_report_summary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, report} <- Jason.decode(content),
         :ok <- AgentProbeReport.validate_failure(report),
         true <- capability_gap_report?(report) do
      [
        %{
          agent: report["agent"],
          path: path,
          run_id: report["run_id"],
          status: report["status"],
          prompt: report["prompt"],
          expected_events: report["expected_events"] || [],
          missing_expected_events: report["missing_expected_events"] || [],
          unsupported_client_capabilities: report["unsupported_client_capabilities"] || [],
          diagnostics: report["diagnostics"] || []
        }
      ]
    else
      _ -> []
    end
  end

  defp capability_gap_report?(%{
         "agent" => agent,
         "missing_expected_events" => missing,
         "diagnostics" => diagnostics
       })
       when is_binary(agent) and is_list(missing) and missing != [] and is_list(diagnostics) do
    agent != "stub-acp" and
      Enum.any?(diagnostics, fn
        %{"type" => "tool_call_only_capability_gap"} -> true
        _diagnostic -> false
      end)
  end

  defp capability_gap_report?(_report), do: false

  def upsert_agent_config_from_registry_suggestion(%{
        id: key,
        executable: executable,
        args: args,
        env: env
      })
      when is_binary(key) and is_binary(executable) and is_list(args) and is_map(env) do
    attrs = %{
      key: key,
      executable: executable,
      args: args,
      cwd: "{workspace}",
      env: env
    }

    case Repo.get_by(AgentConfig, key: key) do
      nil -> create_agent_config(attrs)
      agent_config -> update_agent_config(agent_config, attrs)
    end
  end

  @spec command(String.t(), String.t()) :: {:ok, command()} | {:error, term()}
  def command("stub-acp", workspace) do
    case System.find_executable("elixir") do
      nil ->
        {:error, {:missing_executable, "elixir"}}

      executable ->
        {:ok,
         %{
           executable: executable,
           args: stub_args(workspace),
           cwd: nil,
           env: [],
           label: "stub-acp"
         }}
    end
  end

  def command("cantrip-familiar", _workspace) do
    with {:ok, executable} <- resolve_executable("mix"),
         {:ok, cwd} <- cantrip_root() do
      {:ok,
       %{
         executable: executable,
         args: ["cantrip.familiar", "--acp"],
         cwd: cwd,
         env: [],
         label: "cantrip-familiar"
       }}
    end
  end

  def command(agent, workspace) when is_binary(agent) do
    case all_configured_agents()[agent] do
      nil -> {:error, {:unknown_agent, agent}}
      spec -> command_from_spec(agent, spec, workspace)
    end
  end

  defp stub_args(workspace) do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.ends_with?(&1, "/ebin"))
    |> Enum.flat_map(&["-pa", &1])
    |> Kernel.++(["priv/agent_stub.exs", workspace])
  end

  defp all_configured_agents do
    Map.merge(persisted_agents(), configured_agents())
  end

  defp configured_agents do
    Application.get_env(:haven, :agents, %{})
  end

  defp cantrip_available do
    case cantrip_root() do
      {:ok, _root} -> [{"cantrip-familiar", "cantrip familiar"}]
      {:error, _reason} -> []
    end
  end

  defp cantrip_root do
    case System.get_env("CANTRIP_ROOT") || Application.get_env(:haven, :cantrip_root) do
      nil -> {:error, {:missing_cwd, "CANTRIP_ROOT"}}
      root -> validate_cwd(root)
    end
  end

  defp persisted_agents do
    if repo_started?() do
      AgentConfig
      |> Repo.all()
      |> Map.new(fn agent_config ->
        {agent_config.key,
         %{
           executable: agent_config.executable,
           args: Map.get(agent_config.args || %{}, "items", []),
           cwd: agent_config.cwd,
           env: agent_config.env || %{}
         }}
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp repo_started? do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  defp command_from_spec(agent, spec, workspace) when is_map(spec) do
    with {:ok, executable} <- fetch_executable(spec),
         {:ok, args} <- fetch_args(spec, workspace),
         {:ok, cwd} <- fetch_cwd(spec, workspace),
         {:ok, env} <- fetch_env(spec, workspace) do
      {:ok, %{executable: executable, args: args, cwd: cwd, env: env, label: agent}}
    end
  end

  defp command_from_spec(_agent, _spec, _workspace), do: {:error, :invalid_agent_spec}

  defp fetch_string(spec, key) do
    case Map.get(spec, key) || Map.get(spec, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_agent_field, key}}
    end
  end

  defp fetch_executable(spec) do
    with {:ok, executable} <- fetch_string(spec, :executable) do
      resolve_executable(executable)
    end
  end

  defp resolve_executable(executable) do
    cond do
      Path.type(executable) == :absolute and executable?(executable) ->
        {:ok, executable}

      Path.type(executable) == :absolute ->
        {:error, {:missing_executable, executable}}

      String.contains?(executable, "/") ->
        executable
        |> Path.expand()
        |> resolve_executable()

      resolved = System.find_executable(executable) ->
        {:ok, resolved}

      true ->
        {:error, {:missing_executable, executable}}
    end
  end

  defp executable?(path) do
    with true <- File.regular?(path),
         {:ok, stat} <- File.stat(path) do
      (stat.mode &&& 0o111) != 0
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp fetch_args(spec, workspace) do
    args = Map.get(spec, :args) || Map.get(spec, "args") || []

    if is_list(args) and Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &String.replace(&1, "{workspace}", workspace))}
    else
      {:error, {:invalid_agent_field, :args}}
    end
  end

  defp fetch_cwd(spec, workspace) do
    case Map.get(spec, :cwd) || Map.get(spec, "cwd") do
      nil ->
        {:ok, nil}

      cwd when is_binary(cwd) and cwd != "" ->
        cwd
        |> String.replace("{workspace}", workspace)
        |> validate_cwd()

      _ ->
        {:error, {:invalid_agent_field, :cwd}}
    end
  end

  defp validate_cwd(cwd) do
    cwd = Path.expand(cwd)

    if File.dir?(cwd) do
      {:ok, cwd}
    else
      {:error, {:missing_cwd, cwd}}
    end
  end

  defp fetch_env(spec, workspace) do
    env = Map.get(spec, :env) || Map.get(spec, "env") || []

    cond do
      is_map(env) ->
        env
        |> Map.to_list()
        |> normalize_env(workspace)

      is_list(env) ->
        normalize_env(env, workspace)

      true ->
        {:error, {:invalid_agent_field, :env}}
    end
  end

  defp normalize_env(env, workspace) do
    if Enum.all?(env, &valid_env_pair?/1) do
      {:ok,
       Enum.map(env, fn {name, value} ->
         {to_string(name), String.replace(value, "{workspace}", workspace)}
       end)
       |> Enum.sort_by(fn {name, _value} -> name end)}
    else
      {:error, {:invalid_agent_field, :env}}
    end
  end

  defp valid_env_pair?({name, value}) when is_binary(value) do
    (is_atom(name) or is_binary(name)) and String.match?(to_string(name), @env_name_regex)
  end

  defp valid_env_pair?(_pair), do: false
end
