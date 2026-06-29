defmodule HavenWeb.InboxLive do
  use HavenWeb, :live_view

  alias Haven.Agents
  alias Haven.Runs
  alias Haven.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Haven")
     |> assign(:form, to_form(default_run_params()))
     |> assign(:workspace_form, to_form(default_workspace_params(), as: :workspace_config))
     |> assign(:workspace_error, nil)
     |> assign(:editing_workspace_id, nil)
     |> refresh_workspace_assigns()
     |> assign(:agent_config_form, to_form(default_agent_config_params(), as: :agent_config))
     |> assign(:agent_config_error, nil)
     |> assign(:editing_agent_config_id, nil)
     |> assign(:agent_options, Agents.available())
     |> assign(:agent_configs, Agents.list_agent_configs())
     |> assign_runs()}
  end

  @impl true
  def handle_event("create_run", params, socket) do
    attrs = run_attrs(params)

    case Runs.create_run(attrs) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset)) |> assign_runs()}
    end
  end

  def handle_event("archive_run", %{"id" => id}, socket) do
    _ = Runs.archive_run(id)
    {:noreply, assign_runs(socket)}
  end

  def handle_event("save_workspace", %{"workspace_config" => params}, socket) do
    case save_workspace(params, workspace_attrs(params)) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace #{workspace.name} saved")
         |> reset_workspace_form()
         |> refresh_workspace_assigns()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:workspace_form, to_form(params, as: :workspace_config))
         |> assign(:workspace_error, form_error(changeset))}
    end
  end

  def handle_event("edit_workspace", %{"id" => id}, socket) do
    workspace = Workspaces.get_workspace!(id)

    {:noreply,
     socket
     |> assign(:workspace_form, to_form(workspace_form_params(workspace), as: :workspace_config))
     |> assign(:workspace_error, nil)
     |> assign(:editing_workspace_id, workspace.id)}
  end

  def handle_event("cancel_workspace_edit", _params, socket) do
    {:noreply, reset_workspace_form(socket)}
  end

  def handle_event("delete_workspace", %{"id" => id}, socket) do
    workspace = Workspaces.get_workspace!(id)
    {:ok, _workspace} = Workspaces.delete_workspace(workspace)

    {:noreply,
     socket
     |> put_flash(:info, "Workspace #{workspace.name} deleted")
     |> refresh_workspace_assigns()}
  end

  def handle_event("save_agent_config", %{"agent_config" => params}, socket) do
    with {:ok, attrs} <- agent_config_attrs(params),
         {:ok, agent_config} <- save_agent_config(params, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Agent #{agent_config.key} saved")
       |> reset_agent_config_form()
       |> refresh_agent_config_assigns()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply,
         socket
         |> assign(:agent_config_form, to_form(params, as: :agent_config))
         |> assign(:agent_config_error, message)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:agent_config_form, to_form(params, as: :agent_config))
         |> assign(:agent_config_error, form_error(changeset))}
    end
  end

  def handle_event("edit_agent_config", %{"id" => id}, socket) do
    agent_config = Agents.get_agent_config!(id)

    {:noreply,
     socket
     |> assign(
       :agent_config_form,
       to_form(agent_config_form_params(agent_config), as: :agent_config)
     )
     |> assign(:agent_config_error, nil)
     |> assign(:editing_agent_config_id, agent_config.id)}
  end

  def handle_event("cancel_agent_config_edit", _params, socket) do
    {:noreply, reset_agent_config_form(socket)}
  end

  def handle_event("delete_agent_config", %{"id" => id}, socket) do
    agent_config = Agents.get_agent_config!(id)
    {:ok, _agent_config} = Agents.delete_agent_config(agent_config)

    {:noreply,
     socket
     |> put_flash(:info, "Agent #{agent_config.key} deleted")
     |> reset_agent_config_form()
     |> refresh_agent_config_assigns()}
  end

  @impl true
  def handle_info({:run_updated, _run}, socket), do: {:noreply, assign_runs(socket)}

  defp assign_runs(socket) do
    runs = Runs.list_runs()

    socket
    |> assign(:runs, runs)
    |> assign(:needs_you, Enum.filter(runs, &(&1.status == "waiting")))
    |> assign(:running, Enum.filter(runs, &(&1.status in ["initializing", "running"])))
    |> assign(:history, Enum.reject(runs, &(&1.status in ["waiting", "initializing", "running"])))
  end

  defp default_run_params do
    %{
      "title" => "",
      "workspace" => File.cwd!(),
      "workspace_id" => "",
      "agent" => "stub-acp",
      "file_read_policy" => "ask",
      "file_write_policy" => "ask",
      "terminal_create_policy" => "allow"
    }
  end

  defp default_workspace_params do
    %{
      "id" => "",
      "name" => "",
      "path" => File.cwd!()
    }
  end

  defp default_agent_config_params do
    %{
      "id" => "",
      "key" => "",
      "executable" => "",
      "args_text" => "",
      "cwd" => "",
      "env_text" => ""
    }
  end

  defp run_attrs(params) do
    defaults = default_run_params()

    title =
      params
      |> Map.get("title", defaults["title"])
      |> String.trim()

    workspace =
      params
      |> Map.get("workspace", defaults["workspace"])
      |> String.trim()

    workspace_id =
      params
      |> Map.get("workspace_id", defaults["workspace_id"])
      |> String.trim()

    agent =
      params
      |> Map.get("agent", defaults["agent"])
      |> String.trim()

    selected_workspace = selected_workspace_path(workspace_id)
    file_read_policy = capability_policy_value(params, "file_read_policy")
    file_write_policy = capability_policy_value(params, "file_write_policy")

    terminal_create_policy =
      capability_policy_value(params, "terminal_create_policy", ["ask", "allow", "deny"], "allow")

    %{
      "title" => if(title == "", do: "Untitled run", else: title),
      "workspace" =>
        cond do
          selected_workspace -> selected_workspace
          workspace == "" -> defaults["workspace"]
          true -> Path.expand(workspace)
        end,
      "agent" => if(agent == "", do: defaults["agent"], else: agent),
      "capability_policy" => %{
        "file_read" => file_read_policy,
        "file_write" => file_write_policy,
        "terminal_create" => terminal_create_policy
      }
    }
  end

  defp capability_policy_value(params, key, allowed \\ ["ask", "allow", "deny"], default \\ "ask") do
    case Map.get(params, key, default) do
      value when is_binary(value) -> if(value in allowed, do: value, else: default)
      _value -> default
    end
  end

  defp selected_workspace_path(""), do: nil

  defp selected_workspace_path(id) do
    case Workspaces.get_workspace(id) do
      nil -> nil
      workspace -> workspace.path
    end
  end

  defp workspace_attrs(params) do
    %{
      "id" => Map.get(params, "id", ""),
      "name" => Map.get(params, "name", ""),
      "path" => Map.get(params, "path", "")
    }
  end

  defp save_workspace(%{"id" => id}, attrs) when is_binary(id) and id != "" do
    id
    |> Workspaces.get_workspace!()
    |> Workspaces.update_workspace(attrs)
  end

  defp save_workspace(_params, attrs), do: Workspaces.create_workspace(attrs)

  defp refresh_workspace_assigns(socket) do
    workspaces = Workspaces.list_workspaces()

    socket
    |> assign(:workspaces, workspaces)
    |> assign(:workspace_options, workspace_options(workspaces))
  end

  defp workspace_options(workspaces) do
    Enum.map(workspaces, fn workspace ->
      {"#{workspace.name} · #{workspace.path}", workspace.id}
    end)
  end

  defp reset_workspace_form(socket) do
    socket
    |> assign(:workspace_form, to_form(default_workspace_params(), as: :workspace_config))
    |> assign(:workspace_error, nil)
    |> assign(:editing_workspace_id, nil)
  end

  defp workspace_form_params(workspace) do
    %{
      "id" => workspace.id,
      "name" => workspace.name,
      "path" => workspace.path
    }
  end

  defp agent_config_attrs(params) do
    with {:ok, env} <- parse_env(Map.get(params, "env_text", "")) do
      {:ok,
       %{
         "key" => Map.get(params, "key", ""),
         "executable" => Map.get(params, "executable", ""),
         "args" => parse_args(Map.get(params, "args_text", "")),
         "cwd" => Map.get(params, "cwd", ""),
         "env" => env
       }}
    end
  end

  defp save_agent_config(%{"id" => id}, attrs) when is_binary(id) and id != "" do
    id
    |> Agents.get_agent_config!()
    |> Agents.update_agent_config(attrs)
  end

  defp save_agent_config(_params, attrs), do: Agents.create_agent_config(attrs)

  defp refresh_agent_config_assigns(socket) do
    socket
    |> assign(:agent_options, Agents.available())
    |> assign(:agent_configs, Agents.list_agent_configs())
  end

  defp reset_agent_config_form(socket) do
    socket
    |> assign(:agent_config_form, to_form(default_agent_config_params(), as: :agent_config))
    |> assign(:agent_config_error, nil)
    |> assign(:editing_agent_config_id, nil)
  end

  defp agent_config_form_params(agent_config) do
    %{
      "id" => agent_config.id,
      "key" => agent_config.key,
      "executable" => agent_config.executable,
      "args_text" => agent_config_args_text(agent_config),
      "cwd" => agent_config.cwd || "",
      "env_text" => agent_config_env_text(agent_config)
    }
  end

  defp agent_config_args_text(agent_config) do
    agent_config.args
    |> case do
      %{"items" => items} when is_list(items) -> items
      _ -> []
    end
    |> Enum.join("\n")
  end

  defp agent_config_env_text(agent_config) do
    agent_config.env
    |> case do
      env when is_map(env) -> env
      _ -> %{}
    end
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp parse_args(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_env(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, env} ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          if key == "" do
            {:halt, {:error, "Environment lines must use KEY=value"}}
          else
            {:cont, {:ok, Map.put(env, key, String.trim(value))}}
          end

        _ ->
          {:halt, {:error, "Environment lines must use KEY=value"}}
      end
    end)
  end

  defp form_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end

  defp status_class("waiting"), do: badge_class("border-amber-200 bg-amber-50 text-amber-700")
  defp status_class("running"), do: badge_class("border-sky-200 bg-sky-50 text-sky-700")
  defp status_class("initializing"), do: badge_class("border-zinc-200 bg-zinc-50 text-zinc-700")
  defp status_class("failed"), do: badge_class("border-rose-200 bg-rose-50 text-rose-700")
  defp status_class(_), do: badge_class("border-zinc-200 bg-white text-zinc-600")

  defp archivable?(run), do: run.status in ["closed", "failed"]

  defp badge_class(tone) do
    "inline-flex shrink-0 items-center rounded-full border px-2.5 py-1 text-xs font-medium " <>
      tone
  end

  defp run_card(assigns) do
    assigns = assign_new(assigns, :show_archive, fn -> false end)

    ~H"""
    <article class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm transition hover:border-zinc-300 hover:bg-zinc-50">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="truncate font-semibold text-zinc-950">{@run.title}</h3>
          <p class="mt-1 truncate text-sm text-zinc-500">{@run.workspace}</p>
        </div>
        <span class={status_class(@run.status)}>{@run.status}</span>
      </div>
      <div class="mt-3 flex items-center justify-between gap-3">
        <div class="text-xs text-zinc-500">
          {@run.agent} · updated {Calendar.strftime(@run.updated_at, "%H:%M:%S")}
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <.link
            navigate={~p"/runs/#{@run.id}"}
            class="inline-flex h-8 items-center rounded-md border border-zinc-300 bg-white px-3 text-xs font-semibold text-zinc-700 transition hover:bg-zinc-50"
          >
            Open
          </.link>
          <button
            :if={@show_archive and archivable?(@run)}
            id={"archive-run-#{@run.id}"}
            type="button"
            title="Archive run"
            class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white text-zinc-600 transition hover:bg-zinc-50 hover:text-zinc-950"
            phx-click="archive_run"
            phx-value-id={@run.id}
          >
            <.icon name="hero-archive-box" class="size-4" />
          </button>
        </div>
      </div>
    </article>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="haven-inbox" class="min-h-dvh bg-zinc-100 text-zinc-950">
        <section class="mx-auto flex max-w-5xl flex-col gap-6 p-4 md:p-8">
          <header class="grid gap-5 border-b border-zinc-200 pb-5 lg:grid-cols-[minmax(0,1fr)_minmax(420px,560px)] lg:items-end">
            <div>
              <p class="text-sm font-medium text-zinc-500">Haven</p>
              <h1 class="text-3xl font-bold tracking-normal">Agent attention inbox</h1>
            </div>

            <.form
              id="new-run-form"
              for={@form}
              phx-submit="create_run"
              class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-3 shadow-sm"
            >
              <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_9rem]">
                <.input
                  field={@form[:title]}
                  type="text"
                  label="Run goal"
                  placeholder="Review agent changes"
                  autocomplete="off"
                />
                <.input
                  field={@form[:agent]}
                  type="select"
                  label="Agent"
                  options={@agent_options}
                />
              </div>
              <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] md:items-end">
                <.input
                  field={@form[:workspace_id]}
                  type="select"
                  label="Saved workspace"
                  prompt="Manual path"
                  options={@workspace_options}
                />
                <.input
                  field={@form[:workspace]}
                  type="text"
                  label="Workspace"
                  placeholder="/path/to/workspace"
                  autocomplete="off"
                />
                <button
                  id="start-run-button"
                  class="mb-2 h-10 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Start
                </button>
              </div>
              <div class="grid gap-3 md:grid-cols-3">
                <.input
                  field={@form[:file_read_policy]}
                  type="select"
                  label="File reads"
                  options={[{"Ask", "ask"}, {"Allow", "allow"}, {"Deny", "deny"}]}
                />
                <.input
                  field={@form[:file_write_policy]}
                  type="select"
                  label="File writes"
                  options={[{"Ask", "ask"}, {"Allow", "allow"}, {"Deny", "deny"}]}
                />
                <.input
                  field={@form[:terminal_create_policy]}
                  type="select"
                  label="Terminals"
                  options={[{"Ask", "ask"}, {"Allow", "allow"}, {"Deny", "deny"}]}
                />
              </div>
            </.form>
          </header>

          <section
            id="workspaces-panel"
            class="grid gap-4 border-b border-zinc-200 pb-6 lg:grid-cols-[minmax(0,1fr)_minmax(420px,560px)]"
          >
            <div>
              <h2 class="text-sm font-semibold uppercase text-zinc-500">Workspaces</h2>
              <div
                id="workspace-list"
                class="mt-3 overflow-hidden rounded-lg border border-zinc-200 bg-white"
              >
                <div
                  :if={@workspaces == []}
                  id="workspace-empty"
                  class="px-4 py-5 text-sm text-zinc-500"
                >
                  No saved workspaces yet.
                </div>
                <div
                  :for={workspace <- @workspaces}
                  id={"workspace-#{workspace.id}"}
                  class="border-t border-zinc-100 px-4 py-3 first:border-t-0"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="truncate text-sm font-semibold text-zinc-950">{workspace.name}</p>
                      <p class="mt-1 truncate text-xs text-zinc-500">{workspace.path}</p>
                    </div>
                    <div class="flex shrink-0 items-center gap-2">
                      <button
                        id={"edit-workspace-#{workspace.id}"}
                        type="button"
                        title="Edit workspace"
                        class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white text-zinc-600 transition hover:bg-zinc-50 hover:text-zinc-950"
                        phx-click="edit_workspace"
                        phx-value-id={workspace.id}
                      >
                        <.icon name="hero-pencil-square" class="size-4" />
                      </button>
                      <button
                        id={"delete-workspace-#{workspace.id}"}
                        type="button"
                        title="Delete workspace"
                        class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white text-zinc-600 transition hover:border-rose-200 hover:bg-rose-50 hover:text-rose-700"
                        phx-click="delete_workspace"
                        phx-value-id={workspace.id}
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <.form
              id="workspace-form"
              for={@workspace_form}
              phx-submit="save_workspace"
              class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-3 shadow-sm"
            >
              <.input field={@workspace_form[:id]} type="hidden" />
              <p
                :if={@workspace_error}
                id="workspace-error"
                class="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
              >
                {@workspace_error}
              </p>
              <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
                <.input
                  field={@workspace_form[:name]}
                  type="text"
                  label="Name"
                  placeholder="Haven"
                  autocomplete="off"
                />
                <.input
                  field={@workspace_form[:path]}
                  type="text"
                  label="Path"
                  placeholder="/path/to/repo"
                  autocomplete="off"
                />
              </div>
              <div class="flex justify-end gap-2">
                <button
                  :if={@editing_workspace_id}
                  id="cancel-workspace-edit-button"
                  type="button"
                  class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                  phx-click="cancel_workspace_edit"
                >
                  Cancel
                </button>
                <button
                  id="save-workspace-button"
                  class="h-10 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800"
                >
                  {if @editing_workspace_id, do: "Update Workspace", else: "Save Workspace"}
                </button>
              </div>
            </.form>
          </section>

          <section
            id="agent-configs-panel"
            class="grid gap-4 border-b border-zinc-200 pb-6 lg:grid-cols-[minmax(0,1fr)_minmax(420px,560px)]"
          >
            <div>
              <h2 class="text-sm font-semibold uppercase text-zinc-500">Agent Setup</h2>
              <div
                id="agent-config-list"
                class="mt-3 overflow-hidden rounded-lg border border-zinc-200 bg-white"
              >
                <div
                  :if={@agent_configs == []}
                  id="agent-config-empty"
                  class="px-4 py-5 text-sm text-zinc-500"
                >
                  No saved agent commands yet.
                </div>
                <div
                  :for={agent_config <- @agent_configs}
                  id={"agent-config-#{agent_config.key}"}
                  class="border-t border-zinc-100 px-4 py-3 first:border-t-0"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="truncate text-sm font-semibold text-zinc-950">{agent_config.key}</p>
                      <p class="mt-1 truncate text-xs text-zinc-500">{agent_config.executable}</p>
                    </div>
                    <div class="flex shrink-0 items-center gap-2">
                      <span class="rounded-full border border-zinc-200 px-2 py-1 text-xs text-zinc-500">
                        {length(Map.get(agent_config.args || %{}, "items", []))} args
                      </span>
                      <button
                        id={"edit-agent-config-#{agent_config.key}"}
                        type="button"
                        title="Edit agent"
                        class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white text-zinc-600 transition hover:bg-zinc-50 hover:text-zinc-950"
                        phx-click="edit_agent_config"
                        phx-value-id={agent_config.id}
                      >
                        <.icon name="hero-pencil-square" class="size-4" />
                      </button>
                      <button
                        id={"delete-agent-config-#{agent_config.key}"}
                        type="button"
                        title="Delete agent"
                        class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white text-zinc-600 transition hover:border-rose-200 hover:bg-rose-50 hover:text-rose-700"
                        phx-click="delete_agent_config"
                        phx-value-id={agent_config.id}
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <.form
              id="agent-config-form"
              for={@agent_config_form}
              phx-submit="save_agent_config"
              class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-3 shadow-sm"
            >
              <.input field={@agent_config_form[:id]} type="hidden" />
              <p
                :if={@agent_config_error}
                id="agent-config-error"
                class="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
              >
                {@agent_config_error}
              </p>
              <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
                <.input
                  field={@agent_config_form[:key]}
                  type="text"
                  label="Agent key"
                  placeholder="claude-local"
                  autocomplete="off"
                />
                <.input
                  field={@agent_config_form[:executable]}
                  type="text"
                  label="Executable"
                  placeholder="agent-command"
                  autocomplete="off"
                />
              </div>
              <.input
                field={@agent_config_form[:args_text]}
                type="textarea"
                label="Arguments"
                placeholder="--workspace\n{workspace}"
                rows="3"
              />
              <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
                <.input
                  field={@agent_config_form[:cwd]}
                  type="text"
                  label="Working directory"
                  placeholder="{workspace}"
                  autocomplete="off"
                />
                <.input
                  field={@agent_config_form[:env_text]}
                  type="textarea"
                  label="Environment"
                  placeholder="TOKEN=..."
                  rows="3"
                />
              </div>
              <div class="flex justify-end gap-2">
                <button
                  :if={@editing_agent_config_id}
                  id="cancel-agent-config-edit-button"
                  type="button"
                  class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                  phx-click="cancel_agent_config_edit"
                >
                  Cancel
                </button>
                <button
                  id="save-agent-config-button"
                  class="h-10 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800"
                >
                  {if @editing_agent_config_id, do: "Update Agent", else: "Save Agent"}
                </button>
              </div>
            </.form>
          </section>

          <section :if={@needs_you != []} class="space-y-3">
            <h2 class="text-sm font-semibold uppercase text-zinc-500">Needs You</h2>
            <div class="grid gap-3">
              <.run_card :for={run <- @needs_you} run={run} />
            </div>
          </section>

          <section :if={@running != []} class="space-y-3">
            <h2 class="text-sm font-semibold uppercase text-zinc-500">Running</h2>
            <div class="grid gap-3 md:grid-cols-2">
              <.run_card :for={run <- @running} run={run} />
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="text-sm font-semibold uppercase text-zinc-500">History</h2>
            <div
              :if={@history == []}
              class="rounded-lg border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"
            >
              No quiet runs yet. Start one above.
            </div>
            <div class="grid gap-3 md:grid-cols-2">
              <.run_card :for={run <- @history} run={run} show_archive={true} />
            </div>
          </section>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
