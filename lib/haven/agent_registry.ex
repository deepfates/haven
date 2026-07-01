defmodule Haven.AgentRegistry do
  @moduledoc """
  Reads the public ACP registry and turns entries into Haven agent command specs.
  """

  @registry_url "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"

  @type suggestion :: %{
          id: String.t(),
          name: String.t(),
          version: String.t() | nil,
          description: String.t() | nil,
          executable: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          package: String.t()
        }

  @spec fetch_suggestions(keyword()) :: {:ok, [suggestion()]} | {:error, term()}
  def fetch_suggestions(opts \\ []) do
    url = Keyword.get(opts, :url, @registry_url)

    case Req.get(url, receive_timeout: Keyword.get(opts, :timeout, 10_000)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, suggestions(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec suggestions(map()) :: [suggestion()]
  def suggestions(%{"agents" => agents}) when is_list(agents) do
    agents
    |> Enum.flat_map(&suggestion/1)
    |> Enum.sort_by(& &1.id)
  end

  def suggestions(_registry), do: []

  @spec env_keys(suggestion()) :: [String.t()]
  def env_keys(%{env: env}) when is_map(env) do
    env
    |> Map.keys()
    |> Enum.sort()
  end

  def env_keys(_suggestion), do: []

  @spec trial_command(suggestion(), Path.t()) :: String.t()
  def trial_command(suggestion, workspace) do
    agent_json =
      %{
        suggestion.id => %{
          executable: suggestion.executable,
          args: suggestion.args,
          cwd: "{workspace}",
          env: suggestion.env
        }
      }
      |> Jason.encode!()

    [
      "HAVEN_AGENTS_JSON=#{shell_arg(agent_json)}",
      "mix",
      "haven.agent_probe",
      "--list-agents",
      "--preflight",
      "--proof-commands",
      "--workspace",
      shell_arg(workspace)
    ]
    |> Enum.join(" ")
  end

  defp suggestion(%{"id" => id, "distribution" => %{"npx" => %{"package" => package}}} = agent)
       when is_binary(id) and id != "" and is_binary(package) and package != "" do
    args = ["-y", package] ++ string_list(get_in(agent, ["distribution", "npx", "args"]))

    [
      %{
        id: id,
        name: agent["name"] || id,
        version: agent["version"],
        description: agent["description"],
        executable: "npx",
        args: args,
        env: string_map(get_in(agent, ["distribution", "npx", "env"])),
        package: package
      }
    ]
  end

  defp suggestion(_agent), do: []

  defp string_list(values) when is_list(values) do
    Enum.filter(values, &is_binary/1)
  end

  defp string_list(_values), do: []

  defp string_map(values) when is_map(values) do
    values
    |> Enum.filter(fn {key, value} -> is_binary(key) and is_binary(value) end)
    |> Map.new()
  end

  defp string_map(_values), do: %{}

  defp shell_arg(value) do
    value = to_string(value)

    if String.match?(value, ~r/^[A-Za-z0-9_.,:\/=@+-]+$/) do
      value
    else
      "'#{String.replace(value, "'", "'\"'\"'")}'"
    end
  end
end
