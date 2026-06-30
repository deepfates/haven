defmodule HavenWeb.InboxLive do
  use HavenWeb, :live_view

  alias Haven.AgentProbe
  alias Haven.Agents
  alias Haven.Events
  alias Haven.Runs
  alias Haven.Workspaces

  @run_filters [
    {"all", "All"},
    {"needs_you", "Needs You"},
    {"running", "Running"},
    {"history", "History"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Haven")
     |> assign(:run_filter, "all")
     |> assign(:run_search, "")
     |> assign(:form, to_form(default_run_params()))
     |> assign(:workspace_form, to_form(default_workspace_params(), as: :workspace_config))
     |> assign(:workspace_error, nil)
     |> assign(:editing_workspace_id, nil)
     |> refresh_workspace_assigns()
     |> assign(:agent_config_form, to_form(default_agent_config_params(), as: :agent_config))
     |> assign(:agent_config_error, nil)
     |> assign(:editing_agent_config_id, nil)
     |> refresh_agent_config_assigns()
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

  def handle_event("filter_runs", %{"filter" => filter}, socket) do
    filter = if valid_run_filter?(filter), do: filter, else: "all"

    {:noreply,
     socket
     |> assign(:run_filter, filter)
     |> assign_runs()}
  end

  def handle_event("search_runs", %{"run_search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:run_search, normalize_search_query(query))
     |> assign_runs()}
  end

  def handle_event("clear_run_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:run_search, "")
     |> assign_runs()}
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
       |> refresh_agent_config_assigns()
       |> push_event("clear_agent_config_form", %{id: "agent-config-form"})}
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

  def handle_info({:run_event_appended, _event}, socket), do: {:noreply, assign_runs(socket)}

  defp assign_runs(socket) do
    runs =
      Runs.list_runs()
      |> attach_latest_events()

    run_search = socket.assigns[:run_search] || ""
    visible_runs = filter_runs_by_search(runs, run_search)

    needs_you = Enum.filter(visible_runs, &(&1.status == "waiting"))
    running = Enum.filter(visible_runs, &(&1.status in ["initializing", "running"]))
    history = Enum.reject(visible_runs, &(&1.status in ["waiting", "initializing", "running"]))

    run_filter = socket.assigns[:run_filter] || "all"

    {visible_needs_you, visible_running, visible_history} =
      visible_run_groups(run_filter, needs_you, running, history)

    socket
    |> assign(:runs, runs)
    |> assign(:visible_runs, visible_runs)
    |> assign(:run_search, run_search)
    |> assign(:run_filters, @run_filters)
    |> assign(:run_filter_counts, %{
      "all" => length(visible_runs),
      "needs_you" => length(needs_you),
      "running" => length(running),
      "history" => length(history)
    })
    |> assign(:needs_you, visible_needs_you)
    |> assign(:running, visible_running)
    |> assign(:history, visible_history)
    |> assign(
      :filtered_runs_empty?,
      (run_filter != "all" or run_search != "") and
        visible_needs_you == [] and visible_running == [] and visible_history == []
    )
    |> assign(:searched_runs_empty?, run_search != "" and visible_runs == [])
  end

  defp visible_run_groups("needs_you", needs_you, _running, _history), do: {needs_you, [], []}
  defp visible_run_groups("running", _needs_you, running, _history), do: {[], running, []}
  defp visible_run_groups("history", _needs_you, _running, history), do: {[], [], history}
  defp visible_run_groups(_filter, needs_you, running, history), do: {needs_you, running, history}

  defp valid_run_filter?(filter) do
    Enum.any?(@run_filters, fn {value, _label} -> value == filter end)
  end

  defp attach_latest_events(runs) do
    latest_events =
      runs
      |> Enum.map(& &1.id)
      |> Events.latest_by_run_id()

    Enum.map(runs, fn run ->
      Map.put(run, :latest_event, Map.get(latest_events, run.id))
    end)
  end

  defp normalize_search_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_search_query(_query), do: ""

  defp filter_runs_by_search(runs, ""), do: runs

  defp filter_runs_by_search(runs, query) do
    normalized_query = String.downcase(query)

    Enum.filter(runs, fn run ->
      run
      |> run_search_text()
      |> String.downcase()
      |> String.contains?(normalized_query)
    end)
  end

  defp run_search_text(run) do
    [
      run.title,
      run.workspace,
      run.agent,
      run.status,
      latest_activity(run.latest_event)
    ]
    |> Enum.join(" ")
  end

  defp default_run_params do
    %{
      "title" => "",
      "workspace" => File.cwd!(),
      "workspace_id" => "",
      "agent" => "stub-acp",
      "file_read_policy" => "ask",
      "file_read_paths" => "",
      "file_write_policy" => "ask",
      "file_write_paths" => "",
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
    file_read_paths = capability_path_scope_value(params, "file_read_paths")
    file_write_policy = capability_policy_value(params, "file_write_policy")
    file_write_paths = capability_path_scope_value(params, "file_write_paths")

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
        "file_read_paths" => file_read_paths,
        "file_write" => file_write_policy,
        "file_write_paths" => file_write_paths,
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

  defp capability_path_scope_value(params, key) do
    params
    |> Map.get(key, "")
    |> parse_path_scope()
  end

  defp parse_path_scope(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_path_scope(_value), do: []

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
    |> assign(:agent_inventory, agent_inventory_by_key())
  end

  defp agent_inventory_by_key do
    File.cwd!()
    |> AgentProbe.agent_inventory()
    |> Map.new(&{&1.agent, &1})
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

  defp run_filter_button_class(filter, active_filter) do
    [
      "inline-flex h-9 items-center rounded-md border px-3 text-xs font-semibold transition",
      filter == active_filter && "border-zinc-950 bg-zinc-950 text-white",
      filter != active_filter && "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50"
    ]
  end

  defp badge_class(tone) do
    "inline-flex shrink-0 items-center rounded-full border px-2.5 py-1 text-xs font-medium " <>
      tone
  end

  defp latest_activity(nil), do: "No events yet"

  defp latest_activity(%{type: "permission_requested", payload: payload}) do
    title = get_in(payload, ["toolCall", "title"]) || "permission requested"
    "Needs decision: #{title}"
  end

  defp latest_activity(%{type: "permission_resolved", payload: %{"option_id" => option_id}}) do
    "Decision recorded: #{option_id}"
  end

  defp latest_activity(%{type: "agent_message_chunk", payload: %{"text" => text}}) do
    "Agent: #{one_line(text)}"
  end

  defp latest_activity(%{type: "user_message", payload: %{"text" => text}}) do
    "You: #{one_line(text)}"
  end

  defp latest_activity(%{type: "file_read_succeeded", payload: %{"path" => path}}) do
    "Read file: #{path}"
  end

  defp latest_activity(%{type: "file_write_succeeded", payload: %{"path" => path}}) do
    "Wrote file: #{path}"
  end

  defp latest_activity(%{type: "file_write_denied", payload: %{"path" => path}}) do
    "File write denied: #{path}"
  end

  defp latest_activity(%{type: "terminal_created", payload: %{"command" => command}}) do
    "Started terminal: #{command}"
  end

  defp latest_activity(%{type: "terminal_output_succeeded", payload: %{"command" => command}}) do
    "Terminal output: #{command}"
  end

  defp latest_activity(%{type: "turn_finished"}), do: "Turn finished"
  defp latest_activity(%{type: "turn_failed"}), do: "Turn failed"
  defp latest_activity(%{type: "turn_cancelled"}), do: "Turn cancelled"
  defp latest_activity(%{type: "agent_process_exited"}), do: "Agent process exited"
  defp latest_activity(%{type: "agent_protocol_failed"}), do: "Agent protocol failed"
  defp latest_activity(%{type: "agent_session_started"}), do: "Agent session started"
  defp latest_activity(%{type: "agent_initialized"}), do: "Agent initialized"
  defp latest_activity(%{type: "run_created"}), do: "Run created"
  defp latest_activity(%{type: type}), do: event_label(type)

  defp latest_activity_time(nil), do: nil

  defp latest_activity_time(%{inserted_at: inserted_at}),
    do: Calendar.strftime(inserted_at, "%H:%M:%S")

  defp one_line(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp event_label(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp agent_evidence_label(%{real_agent_candidate: true}), do: "Static candidate"
  defp agent_evidence_label(%{status: "invalid"}), do: "Invalid command"
  defp agent_evidence_label(_inventory), do: "Local harness"

  defp agent_evidence_class(%{real_agent_candidate: true}),
    do: badge_class("border-emerald-200 bg-emerald-50 text-emerald-700")

  defp agent_evidence_class(%{status: "invalid"}),
    do: badge_class("border-rose-200 bg-rose-50 text-rose-700")

  defp agent_evidence_class(_inventory),
    do: badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")

  defp agent_evidence_reason(%{real_agent_rejection_reasons: []}) do
    "command resolves; not ACP evidence until preflight or a generated probe passes"
  end

  defp agent_evidence_reason(%{real_agent_rejection_reasons: reasons}) when is_list(reasons),
    do: Enum.join(reasons, "; ")

  defp agent_evidence_reason(_inventory), do: "agent readiness unknown"

  defp agent_probe_commands(%{real_agent_candidate: true, agent: agent}) do
    [
      %{
        id: "basic",
        label: "Basic boot proof",
        command:
          probe_command(agent, [
            "--expect-event",
            "agent_initialized",
            "--expect-event",
            "agent_session_started",
            "--expect-event",
            "turn_finished",
            "--report",
            "docs/probes/#{agent}-basic.json"
          ])
      },
      %{
        id: "terminal-denied",
        label: "Capability guard proof",
        command:
          probe_command(agent, [
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
            "docs/probes/#{agent}-terminal-denied.json"
          ])
      },
      %{
        id: "file-read",
        label: "File read proof",
        command:
          probe_command(agent, [
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
            "docs/probes/#{agent}-file-read.json"
          ])
      },
      %{
        id: "file-write-approval",
        label: "File write approval proof",
        command:
          probe_command(agent, [
            "--prompt",
            "write Grei probe sentinel to notes/haven-probe.txt through the client file-write capability",
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
            "docs/probes/#{agent}-file-write-approval.json"
          ])
      },
      %{
        id: "terminal-approval",
        label: "Terminal approval proof",
        command:
          probe_command(agent, [
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
            "docs/probes/#{agent}-terminal-approval.json"
          ])
      }
    ]
  end

  defp agent_probe_commands(_inventory), do: []

  defp probe_command(agent, args) do
    [
      "mix",
      "haven.agent_probe",
      "--agent",
      agent,
      "--workspace",
      File.cwd!(),
      "--require-real-agent"
      | args
    ]
    |> Enum.map_join(" ", &shell_arg/1)
  end

  defp agent_registry_command do
    [
      "mix",
      "haven.agent_probe",
      "--list-agents",
      "--registry",
      "--workspace",
      File.cwd!()
    ]
    |> Enum.map_join(" ", &shell_arg/1)
  end

  defp shell_arg(value) do
    value = to_string(value)

    if String.match?(value, ~r/^[A-Za-z0-9_.,:\/=@+-]+$/) do
      value
    else
      "'#{String.replace(value, "'", "'\"'\"'")}'"
    end
  end

  defp run_card(assigns) do
    assigns = assign_new(assigns, :show_archive, fn -> false end)

    ~H"""
    <article class="border-b border-zinc-200 bg-white px-4 py-3 transition last:border-b-0 hover:bg-zinc-50">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="truncate text-sm font-semibold text-zinc-950">{@run.title}</h3>
          <p class="mt-1 truncate text-xs text-zinc-500">{@run.workspace}</p>
        </div>
        <span class={status_class(@run.status)}>{@run.status}</span>
      </div>
      <div class="mt-2 flex items-center justify-between gap-3">
        <div class="min-w-0 text-xs text-zinc-500">
          <p class="truncate">
            {@run.agent} · started {Calendar.strftime(@run.inserted_at, "%H:%M:%S")} · updated {Calendar.strftime(
              @run.updated_at,
              "%H:%M:%S"
            )}
          </p>
          <p id={"run-#{@run.id}-latest-activity"} class="mt-1 truncate text-zinc-700">
            {latest_activity(@run.latest_event)}
            <span :if={latest_activity_time(@run.latest_event)} class="text-zinc-400">
              · {latest_activity_time(@run.latest_event)}
            </span>
          </p>
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
      <main id="haven-inbox" class="min-h-dvh bg-white text-zinc-950">
        <section class="mx-auto flex max-w-5xl flex-col gap-5 px-4 py-4 md:px-8 md:py-6">
          <header class="grid gap-4 border-b border-zinc-200 pb-4 lg:grid-cols-[minmax(0,1fr)_minmax(420px,560px)] lg:items-end">
            <div>
              <p class="text-sm font-medium text-zinc-500">Haven</p>
              <h1 class="text-2xl font-semibold tracking-normal">Inbox</h1>
              <p class="mt-1 text-sm text-zinc-500">Agent work across your folders.</p>
            </div>

            <.form
              id="new-run-form"
              for={@form}
              phx-submit="create_run"
              class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-3"
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
              <details class="rounded-md border border-zinc-200 px-3 py-2">
                <summary class="cursor-pointer text-sm font-medium text-zinc-700">
                  Capability policy
                </summary>
                <div class="mt-3 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_minmax(160px,0.7fr)]">
                  <div class="grid gap-2">
                    <.input
                      field={@form[:file_read_policy]}
                      type="select"
                      label="File reads"
                      options={[{"Ask", "ask"}, {"Allow", "allow"}, {"Deny", "deny"}]}
                    />
                    <.input
                      field={@form[:file_read_paths]}
                      type="text"
                      label="Read paths"
                      placeholder="README.md, docs"
                      autocomplete="off"
                    />
                  </div>
                  <div class="grid gap-2">
                    <.input
                      field={@form[:file_write_policy]}
                      type="select"
                      label="File writes"
                      options={[{"Ask", "ask"}, {"Allow", "allow"}, {"Deny", "deny"}]}
                    />
                    <.input
                      field={@form[:file_write_paths]}
                      type="text"
                      label="Write paths"
                      placeholder="notes, tmp/output.md"
                      autocomplete="off"
                    />
                  </div>
                  <.input
                    field={@form[:terminal_create_policy]}
                    type="select"
                    label="Terminals"
                    options={[{"Ask", "ask"}, {"Allow", "allow"}, {"Deny", "deny"}]}
                  />
                </div>
              </details>
            </.form>
          </header>

          <form
            id="inbox-search-form"
            phx-change="search_runs"
            phx-submit="search_runs"
            class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]"
          >
            <.input
              id="run_search"
              name="run_search"
              value={@run_search}
              type="search"
              label="Search runs"
              placeholder="Title, folder, agent, status, activity"
              autocomplete="off"
            />
            <button
              :if={@run_search != ""}
              id="clear-inbox-search"
              type="button"
              class="mb-2 h-10 self-end rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
              phx-click="clear_run_search"
            >
              Clear
            </button>
          </form>

          <nav
            id="inbox-run-filters"
            class="flex gap-2 overflow-x-auto pb-1"
            aria-label="Run filters"
          >
            <button
              :for={{filter, label} <- @run_filters}
              id={"inbox-filter-#{filter}"}
              type="button"
              class={run_filter_button_class(filter, @run_filter)}
              phx-click="filter_runs"
              phx-value-filter={filter}
            >
              {label}
              <span class="ml-1 font-mono text-[11px] opacity-70">
                {Map.get(@run_filter_counts, filter, 0)}
              </span>
            </button>
          </nav>

          <div
            :if={@filtered_runs_empty?}
            id="inbox-filter-empty"
            class="rounded-lg border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"
          >
            <%= if @searched_runs_empty? do %>
              No runs match your search.
            <% else %>
              No runs in this view.
            <% end %>
          </div>

          <section :if={@needs_you != []} id="inbox-needs-you-section" class="space-y-2">
            <h2 class="px-1 text-xs font-semibold uppercase text-zinc-500">Needs You</h2>
            <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white">
              <.run_card :for={run <- @needs_you} run={run} />
            </div>
          </section>

          <section :if={@running != []} id="inbox-running-section" class="space-y-2">
            <h2 class="px-1 text-xs font-semibold uppercase text-zinc-500">Running</h2>
            <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white">
              <.run_card :for={run <- @running} run={run} />
            </div>
          </section>

          <section
            :if={@run_filter in ["all", "history"] and !@filtered_runs_empty?}
            id="inbox-history-section"
            class="space-y-2"
          >
            <h2 class="px-1 text-xs font-semibold uppercase text-zinc-500">History</h2>
            <div
              :if={@history == []}
              class="rounded-lg border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"
            >
              No quiet runs yet. Start one above.
            </div>
            <div
              :if={@history != []}
              class="overflow-hidden rounded-lg border border-zinc-200 bg-white"
            >
              <.run_card :for={run <- @history} run={run} show_archive={true} />
            </div>
          </section>

          <details
            id="workspaces-panel"
            class="group border-t border-zinc-200 pt-3"
          >
            <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-2 text-sm font-semibold text-zinc-700 marker:hidden">
              <span>Manage workspaces</span>
              <span class="font-mono text-xs text-zinc-500">{length(@workspaces)}</span>
            </summary>
            <div class="grid gap-4 pt-3 lg:grid-cols-[minmax(0,1fr)_minmax(420px,560px)]">
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
            </div>
          </details>

          <details
            id="agent-configs-panel"
            class="group border-b border-zinc-200 pb-4"
          >
            <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-2 text-sm font-semibold text-zinc-700 marker:hidden">
              <span>Manage agents</span>
              <span class="font-mono text-xs text-zinc-500">{length(@agent_configs)}</span>
            </summary>
            <div class="grid gap-4 pt-3 lg:grid-cols-[minmax(0,1fr)_minmax(420px,560px)]">
              <div>
                <h2 class="text-sm font-semibold uppercase text-zinc-500">Agent Setup</h2>
                <div
                  id="agent-registry-hint"
                  class="mt-3 rounded-lg border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-900"
                >
                  <div class="flex items-start gap-3">
                    <.icon name="hero-sparkles" class="mt-0.5 size-4 shrink-0 text-sky-600" />
                    <div class="min-w-0">
                      <p class="font-semibold">Find real ACP agents from the public registry</p>
                      <code
                        id="agent-registry-command"
                        class="mt-2 block overflow-x-auto rounded-md border border-sky-200 bg-white/80 px-2 py-1 text-[11px] leading-5 text-sky-950"
                      >
                        {agent_registry_command()}
                      </code>
                      <p class="mt-2 text-xs text-sky-800">
                        Registry commands download and run third-party code; use an approved workspace and auth scope before probing.
                      </p>
                    </div>
                  </div>
                </div>
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
                    <% readiness = Map.get(@agent_inventory, agent_config.key, %{}) %>
                    <% probe_commands = agent_probe_commands(readiness) %>
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate text-sm font-semibold text-zinc-950">{agent_config.key}</p>
                        <p class="mt-1 truncate text-xs text-zinc-500">{agent_config.executable}</p>
                        <div :if={probe_commands != []} class="mt-2 space-y-2">
                          <div
                            :for={probe <- probe_commands}
                            id={"agent-config-#{agent_config.key}-probe-#{probe.id}"}
                          >
                            <p class="text-[11px] font-semibold uppercase text-zinc-500">
                              {probe.label}
                            </p>
                            <code
                              id={
                                if probe.id == "basic",
                                  do: "agent-config-#{agent_config.key}-probe-command",
                                  else: "agent-config-#{agent_config.key}-probe-#{probe.id}-command"
                              }
                              class="mt-1 block overflow-x-auto rounded-md border border-zinc-200 bg-zinc-50 px-2 py-1 text-[11px] leading-5 text-zinc-700"
                            >
                              {probe.command}
                            </code>
                          </div>
                        </div>
                        <p
                          :if={agent_evidence_reason(readiness)}
                          id={"agent-config-#{agent_config.key}-evidence-reason"}
                          class="mt-2 truncate text-xs text-zinc-500"
                        >
                          {agent_evidence_reason(readiness)}
                        </p>
                      </div>
                      <div class="flex shrink-0 items-center gap-2">
                        <span
                          id={"agent-config-#{agent_config.key}-evidence"}
                          class={agent_evidence_class(readiness)}
                        >
                          {agent_evidence_label(readiness)}
                        </span>
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
                phx-update="replace"
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
            </div>
          </details>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
