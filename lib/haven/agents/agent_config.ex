defmodule Haven.Agents.AgentConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_configs" do
    field :key, :string
    field :executable, :string
    field :args, :map, default: %{"items" => []}
    field :cwd, :string
    field :env, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(agent_config, attrs) do
    agent_config
    |> cast(normalize_attrs(attrs), [:key, :executable, :args, :cwd, :env])
    |> update_change(:key, &trim_string/1)
    |> update_change(:executable, &trim_string/1)
    |> update_change(:cwd, &blank_to_nil/1)
    |> normalize_args()
    |> normalize_env()
    |> validate_required([:key, :executable, :args, :env])
    |> validate_format(:key, ~r/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/)
    |> unique_constraint(:key)
  end

  defp normalize_attrs(attrs) do
    attrs
    |> normalize_attr_args()
    |> normalize_attr_env()
  end

  defp normalize_attr_args(attrs) do
    case fetch_attr(attrs, :args) do
      {:ok, args} when is_list(args) -> put_attr(attrs, :args, %{"items" => args})
      _ -> attrs
    end
  end

  defp normalize_attr_env(attrs) do
    case fetch_attr(attrs, :env) do
      {:ok, nil} -> put_attr(attrs, :env, %{})
      _ -> attrs
    end
  end

  defp fetch_attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> :error
    end
  end

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, key) do
      Map.put(attrs, key, value)
    else
      Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp normalize_args(changeset) do
    update_change(changeset, :args, fn
      %{"items" => items} when is_list(items) -> %{"items" => Enum.map(items, &to_string/1)}
      %{items: items} when is_list(items) -> %{"items" => Enum.map(items, &to_string/1)}
      items when is_list(items) -> %{"items" => Enum.map(items, &to_string/1)}
      nil -> %{"items" => []}
      other -> other
    end)
    |> validate_change(:args, fn
      :args, %{"items" => items} when is_list(items) ->
        if Enum.all?(items, &is_binary/1), do: [], else: [args: "must contain string items"]

      :args, _args ->
        [args: "must be a list of strings"]
    end)
  end

  defp normalize_env(changeset) do
    update_change(changeset, :env, fn
      nil ->
        %{}

      env when is_map(env) ->
        Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)

      env ->
        env
    end)
    |> validate_change(:env, fn
      :env, env when is_map(env) ->
        if Enum.all?(env, fn {key, value} -> is_binary(key) and key != "" and is_binary(value) end) do
          []
        else
          [env: "must contain string keys and values"]
        end

      :env, _env ->
        [env: "must be a map"]
    end)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
