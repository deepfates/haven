defmodule HavenWeb.RunLive do
  use HavenWeb, :live_view

  alias Haven.AgentProbe
  alias Haven.Agents
  alias Haven.Events
  alias Haven.FileChanges
  alias Haven.PermissionAudits
  alias Haven.Runs
  alias Haven.Runs.Run
  alias Haven.TerminalSessions

  @event_filters [
    {"all", "All"},
    {"app", "App"},
    {"user", "User"},
    {"agent", "Agent"},
    {"client", "Client"},
    {"protocol", "Protocol"},
    {"runtime", "Runtime"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Events.subscribe(id)
      Runs.subscribe()
    end

    {:ok,
     socket
     |> assign(:prompt, "")
     |> assign(:event_filter, "all")
     |> assign(:event_search, "")
     |> assign_run(id)}
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if socket.assigns.can_prompt? and prompt != "" do
      Runs.send_prompt(socket.assigns.run.id, prompt)
    end

    {:noreply, assign(socket, :prompt, "") |> assign_run(socket.assigns.run.id)}
  end

  def handle_event("continue_failed", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if socket.assigns.can_continue_failed? and prompt != "" do
      Runs.continue_failed_run(socket.assigns.run.id, prompt)
    end

    {:noreply, assign(socket, :prompt, "") |> assign_run(socket.assigns.run.id)}
  end

  def handle_event("sample_prompt", %{"text" => text}, socket) do
    if socket.assigns.can_prompt? do
      Runs.send_prompt(socket.assigns.run.id, text)
    end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event(
        "resolve_permission",
        %{"request-id" => request_id, "option-id" => option_id},
        socket
      ) do
    Runs.resolve_permission(socket.assigns.run.id, request_id, option_id)
    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns.can_cancel? do
      Runs.cancel(socket.assigns.run.id)
    end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("reconnect", _params, socket) do
    if socket.assigns.can_reconnect? do
      Runs.reconnect_run(socket.assigns.run.id)
    end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("retry_last_prompt", _params, socket) do
    if socket.assigns.can_retry_last_prompt? do
      Runs.retry_last_prompt(socket.assigns.run.id)
    end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("filter_events", %{"kind" => kind}, socket) do
    kind = if valid_event_filter?(kind), do: kind, else: "all"

    {:noreply,
     socket
     |> assign(:event_filter, kind)
     |> assign_event_projection(socket.assigns.events)}
  end

  def handle_event("search_events", %{"event_search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:event_search, normalize_event_search(query))
     |> assign_event_projection(socket.assigns.events)}
  end

  def handle_event("clear_event_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:event_search, "")
     |> assign_event_projection(socket.assigns.events)}
  end

  @impl true
  def handle_info({:event_appended, _event}, socket) do
    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_info({:run_event_appended, _event}, socket), do: {:noreply, socket}

  def handle_info({:run_updated, %{id: id}}, %{assigns: %{run: %{id: id}}} = socket) do
    {:noreply, assign_run(socket, id)}
  end

  def handle_info({:run_updated, _run}, socket), do: {:noreply, socket}

  defp assign_run(socket, id) do
    run = Runs.get_run!(id)
    events = Events.list_for_run(id)
    file_changes = FileChanges.list_for_run(id)
    terminal_sessions = TerminalSessions.list_for_run(id)
    live? = Runs.started?(run)
    agent_readiness = agent_readiness(run.agent)
    agent_probe_reports = Agents.accepted_probe_reports(run.agent)

    socket
    |> assign(:run, run)
    |> assign(:agent_readiness, agent_readiness)
    |> assign(:agent_probe_reports, agent_probe_reports)
    |> assign(:capability_policy, Run.capability_policy(run.capability_policy))
    |> assign(:file_changes, file_changes)
    |> assign(:file_change_counts, file_change_counts(file_changes))
    |> assign(:permission_audits, PermissionAudits.list_for_run(id))
    |> assign(:terminal_sessions, terminal_sessions)
    |> assign(:terminal_session_counts, terminal_session_counts(terminal_sessions))
    |> assign(:events, events)
    |> assign_event_projection(events)
    |> assign(:live?, live?)
    |> assign(:can_prompt?, live? and run.status == "idle")
    |> assign(:can_cancel?, live? and run.status in ["initializing", "running", "waiting"])
    |> assign(:can_reconnect?, can_reconnect?(run, live?))
    |> assign(:control_notice, control_notice(run, live?))
    |> assign(:prompt_disabled_reason, prompt_disabled_reason(run, live?))
    |> assign(:cancel_disabled_reason, cancel_disabled_reason(run, live?))
    |> assign(:last_user_prompt, last_user_prompt(events))
    |> assign(:can_retry_last_prompt?, can_retry_last_prompt?(run, events))
    |> assign(:can_continue_failed?, can_continue_failed?(run))
    |> assign(:recovery_attention, recovery_attention(run, live?))
    |> assign(:pending_permission, latest_pending_permission(events))
  end

  defp assign_event_projection(socket, events) do
    filter = socket.assigns[:event_filter] || "all"
    search = socket.assigns[:event_search] || ""
    timeline_entries = timeline_entries(events, filter, search)

    socket
    |> assign(:event_filters, @event_filters)
    |> assign(:event_counts, event_counts(events))
    |> assign(:event_search, search)
    |> assign(:timeline_entries, timeline_entries)
  end

  defp valid_event_filter?(kind) do
    Enum.any?(@event_filters, fn {filter, _label} -> filter == kind end)
  end

  defp filter_events(events, "all"), do: events

  defp filter_events(events, filter) do
    Enum.filter(events, &(event_kind(&1.type) == filter))
  end

  defp event_counts(events) do
    counts =
      events
      |> Enum.map(&event_kind(&1.type))
      |> Enum.frequencies()

    Map.put(counts, "all", length(events))
  end

  defp timeline_entries(events, filter, search) do
    paired_results = paired_tool_results(events)
    paired_result_seqs = MapSet.new(Map.values(paired_results), & &1.seq)

    events
    |> filter_events(filter)
    |> Enum.flat_map(fn event ->
      cond do
        event.type == "tool_call" ->
          [%{event: event, result_event: Map.get(paired_results, tool_call_id(event.payload))}]

        event.type == "tool_call_update" and MapSet.member?(paired_result_seqs, event.seq) ->
          []

        true ->
          [%{event: event, result_event: nil}]
      end
    end)
    |> filter_timeline_entries(search)
  end

  defp normalize_event_search(query) when is_binary(query), do: String.trim(query)
  defp normalize_event_search(_query), do: ""

  defp filter_timeline_entries(entries, ""), do: entries

  defp filter_timeline_entries(entries, search) do
    normalized_search = String.downcase(search)

    Enum.filter(entries, fn entry ->
      entry
      |> timeline_entry_search_text()
      |> String.downcase()
      |> String.contains?(normalized_search)
    end)
  end

  defp timeline_entry_search_text(%{event: event, result_event: result_event}) do
    [
      event.type,
      event_kind_label(event.type),
      safe_json(event.payload),
      result_event && result_event.type,
      result_event && safe_json(result_event.payload)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp safe_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp paired_tool_results(events) do
    started_ids =
      events
      |> Enum.filter(&(&1.type == "tool_call"))
      |> MapSet.new(&tool_call_id(&1.payload))

    events
    |> Enum.filter(&(&1.type == "tool_call_update"))
    |> Enum.reduce(%{}, fn event, acc ->
      id = tool_call_id(event.payload)

      if id && MapSet.member?(started_ids, id) do
        Map.put_new(acc, id, event)
      else
        acc
      end
    end)
  end

  defp can_reconnect?(run, live?) do
    is_nil(run.archived_at) and (run.status == "failed" or (not live? and run.status != "closed"))
  end

  defp can_retry_last_prompt?(%{status: "failed", archived_at: nil}, events),
    do: is_binary(last_user_prompt(events))

  defp can_retry_last_prompt?(_run, _events), do: false

  defp can_continue_failed?(%{status: "failed", archived_at: nil}), do: true
  defp can_continue_failed?(_run), do: false

  defp control_notice(%{status: "failed"}, _live?) do
    "This run failed. Restart it before sending another prompt."
  end

  defp control_notice(%{status: "closed"}, _live?) do
    "This run is closed. Its history is available, but it cannot accept prompts."
  end

  defp control_notice(_run, false) do
    "This run is not connected. Reconnect it before sending another prompt."
  end

  defp control_notice(%{status: "waiting"}, _live?) do
    "Waiting for your decision before this run can accept another prompt."
  end

  defp control_notice(%{status: status}, _live?) when status in ["initializing", "running"] do
    "A turn is already in progress. You can cancel it, then send a new prompt."
  end

  defp control_notice(_run, _live?), do: nil

  defp prompt_disabled_reason(%{status: "idle"}, true), do: nil
  defp prompt_disabled_reason(run, live?), do: control_notice(run, live?)

  defp cancel_disabled_reason(%{status: status}, true)
       when status in ["initializing", "running", "waiting"],
       do: nil

  defp cancel_disabled_reason(%{status: "failed"}, _live?) do
    "This run failed. Restart it instead of cancelling."
  end

  defp cancel_disabled_reason(%{status: "closed"}, _live?) do
    "This run is closed. There is no active turn to cancel."
  end

  defp cancel_disabled_reason(_run, false) do
    "This run is not connected. There is no live turn to cancel."
  end

  defp cancel_disabled_reason(_run, _live?), do: "There is no active turn to cancel."

  defp recovery_attention(%{status: "failed"}, _live?) do
    %{
      title: "Run failed",
      body:
        "The agent process is no longer usable. Restart starts a fresh ACP session while keeping this run history intact.",
      action: "Restart"
    }
  end

  defp recovery_attention(%{status: status}, false) when status != "closed" do
    %{
      title: "Run is not connected",
      body:
        "The durable history is available, but no live agent process is attached. Reconnect starts a fresh ACP session for this run.",
      action: "Reconnect"
    }
  end

  defp recovery_attention(_run, _live?), do: nil

  defp latest_pending_permission(events) do
    resolved =
      events
      |> Enum.filter(&(&1.type == "permission_resolved"))
      |> MapSet.new(&to_string(&1.payload["request_id"]))

    events
    |> Enum.filter(&(&1.type == "permission_requested"))
    |> Enum.reject(&MapSet.member?(resolved, to_string(&1.payload["request_id"])))
    |> List.last()
  end

  defp last_user_prompt(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: "user_message", payload: %{"text" => text}} when is_binary(text) -> text
      _event -> nil
    end)
  end

  defp event(assigns) do
    assigns =
      assigns
      |> assign(:event_kind, event_kind(assigns.event.type))
      |> assign(:event_kind_label, event_kind_label(assigns.event.type))
      |> assign_new(:result_event, fn -> nil end)
      |> assign_new(:permission_audits, fn -> [] end)

    ~H"""
    <article
      id={"event-#{@event.seq}"}
      data-event-kind={@event_kind}
      class={event_card_class(@event_kind)}
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <span class="font-mono text-xs uppercase text-zinc-500">
            {event_sequence_label(@event, @result_event)} · {event_type_label(@event, @result_event)}
          </span>
          <span class={event_kind_class(@event_kind)}>
            {@event_kind_label}
          </span>
        </div>
        <span class="text-xs text-zinc-400">
          {Calendar.strftime(@event.inserted_at, "%H:%M:%S")}
        </span>
      </div>

      <div class="mt-2">
        <%= case @event.type do %>
          <% "user_message" -> %>
            <p class="whitespace-pre-wrap">{@event.payload["text"]}</p>
          <% "agent_message_chunk" -> %>
            <p class="whitespace-pre-wrap text-sky-700">{@event.payload["text"]}</p>
          <% "tool_call" -> %>
            <.tool_call_event payload={@event.payload} />
            <div
              :if={@result_event}
              id={"tool-call-result-#{@event.seq}"}
              class="mt-4 border-t border-zinc-200 pt-4"
            >
              <.tool_call_update_event payload={@result_event.payload} />
            </div>
          <% "tool_call_update" -> %>
            <.tool_call_update_event payload={@event.payload} />
          <% "agent_thought_redacted" -> %>
            <p class="font-semibold text-zinc-900">Agent thought redacted</p>
            <p class="mt-1 text-sm text-zinc-600">
              Haven preserved that private agent reasoning occurred without storing its raw text.
            </p>
          <% "permission_requested" -> %>
            <p class="font-semibold">
              {get_in(@event.payload, ["toolCall", "title"]) || "Permission requested"}
            </p>
            <pre class="mt-2 overflow-x-auto rounded-md bg-zinc-100 p-3 text-xs text-zinc-700"><%= Jason.encode!(get_in(@event.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
          <% type when type in ["permission_resolved", "permission_resolution_ignored"] -> %>
            <.permission_resolution_event
              event={@event}
              audit={permission_audit_for_event(@permission_audits, @event)}
            />
          <% type
             when type in [
                    "file_read_requested",
                    "file_read_succeeded",
                    "file_read_failed",
                    "file_read_denied",
                    "file_write_requested",
                    "file_write_succeeded",
                    "file_write_failed",
                    "file_write_denied",
                    "terminal_create_requested",
                    "terminal_created",
                    "terminal_create_denied",
                    "terminal_create_failed",
                    "terminal_wait_requested",
                    "terminal_wait_succeeded",
                    "terminal_wait_failed",
                    "terminal_output_requested",
                    "terminal_output_succeeded",
                    "terminal_output_failed",
                    "terminal_release_requested",
                    "terminal_released",
                    "terminal_release_failed",
                    "terminal_kill_requested",
                    "terminal_kill_succeeded",
                    "terminal_kill_failed"
                  ] -> %>
            <.client_capability_event seq={@event.seq} type={@event.type} payload={@event.payload} />
          <% "run_reconnect_requested" -> %>
            <p class="font-semibold text-zinc-900">Reconnect requested</p>
            <p class="mt-1 text-sm text-zinc-600">
              Previous status: {@event.payload["previous_status"] || "unknown"}
            </p>
          <% "turn_retry_requested" -> %>
            <p class="font-semibold text-zinc-900">Retry requested</p>
            <p class="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
              {@event.payload["prompt"] || "Last prompt"}
            </p>
          <% "turn_continue_requested" -> %>
            <p class="font-semibold text-zinc-900">Continue requested</p>
            <p class="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
              {@event.payload["prompt"] || "Next prompt"}
            </p>
          <% "turn_failed" -> %>
            <p class="font-semibold text-rose-700">Turn failed</p>
            <p class="mt-1 text-sm text-zinc-600">
              {@event.payload["error"] || "unknown error"}
            </p>
            <p
              :if={@event.payload["actor"]}
              class="mt-1 text-xs uppercase tracking-wide text-zinc-500"
            >
              {@event.payload["actor"]}
            </p>
          <% type
             when type in [
                    "agent_start_failed",
                    "agent_protocol_failed",
                    "agent_process_down"
                  ] -> %>
            <.runtime_failure_event seq={@event.seq} type={@event.type} payload={@event.payload} />
          <% _ -> %>
            <pre class="overflow-x-auto rounded-md bg-zinc-100 p-3 text-xs text-zinc-700"><%= Jason.encode!(@event.payload, pretty: true) %></pre>
        <% end %>
      </div>
    </article>
    """
  end

  defp runtime_failure_event(assigns) do
    assigns =
      assigns
      |> assign(:title, runtime_failure_title(assigns.type))
      |> assign(:reason, runtime_failure_reason(assigns.payload))
      |> assign(:fields, runtime_failure_fields(assigns.type, assigns.payload))

    ~H"""
    <div id={"runtime-failure-#{@seq}"} class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-rose-700 px-2 py-1 text-xs font-semibold uppercase text-white">
          Runtime failure
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
        <span class={client_event_status_class("Failed")}>
          Failed
        </span>
      </div>

      <p
        id={"runtime-failure-#{@seq}-reason"}
        class="whitespace-pre-wrap text-sm font-medium text-rose-700"
      >
        {@reason}
      </p>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :for={field <- @fields} id={"runtime-failure-#{@seq}-#{field.id}"} class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">{field.label}</dt>
          <dd class="truncate font-mono text-xs">{field.value}</dd>
        </div>
      </dl>

      <details class="rounded-md border border-zinc-200 bg-zinc-50 p-3">
        <summary class="cursor-pointer text-xs font-semibold uppercase text-zinc-500">
          Event payload
        </summary>
        <pre class="mt-2 max-h-48 overflow-auto text-xs text-zinc-700"><%= Jason.encode!(@payload, pretty: true) %></pre>
      </details>
    </div>
    """
  end

  defp client_capability_event(assigns) do
    assigns =
      assigns
      |> assign(:title, client_event_title(assigns.type))
      |> assign(:status, client_event_status(assigns.type))
      |> assign(:tag, client_event_tag(assigns.type))
      |> assign(:fields, client_event_fields(assigns.type, assigns.payload))
      |> assign(:error, client_event_error(assigns.payload))

    ~H"""
    <div class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-amber-600 px-2 py-1 text-xs font-semibold uppercase text-white">
          {@tag}
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
        <span class={client_event_status_class(@status)}>
          {@status}
        </span>
      </div>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :for={field <- @fields} id={"client-event-#{@seq}-#{field.id}"} class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">{field.label}</dt>
          <dd class="truncate font-mono text-xs">{field.value}</dd>
        </div>
      </dl>

      <p :if={@error} id={"client-event-#{@seq}-error"} class="text-sm font-medium text-rose-700">
        {@error}
      </p>
    </div>
    """
  end

  defp permission_resolution_event(assigns) do
    assigns =
      assigns
      |> assign(:title, permission_resolution_title(assigns.event, assigns.audit))
      |> assign(:status, permission_resolution_status(assigns.event, assigns.audit))
      |> assign(:fields, permission_resolution_fields(assigns.event, assigns.audit))

    ~H"""
    <div id={"permission-decision-#{@event.seq}"} class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-amber-600 px-2 py-1 text-xs font-semibold uppercase text-white">
          Decision
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
        <span class={permission_status_class(@status)}>
          {@status}
        </span>
      </div>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div
          :for={field <- @fields}
          id={"permission-decision-#{@event.seq}-#{field.id}"}
          class="min-w-0"
        >
          <dt class="text-xs font-semibold uppercase text-zinc-500">{field.label}</dt>
          <dd class="truncate font-mono text-xs">{field.value}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp tool_call_event(assigns) do
    assigns =
      assigns
      |> assign(:kind, assigns.payload["kind"] || "tool")
      |> assign(:title, assigns.payload["title"] || "Tool call")
      |> assign(:path, tool_call_path(assigns.payload))
      |> assign(:command, get_in(assigns.payload, ["rawInput", "command"]))
      |> assign(
        :cwd,
        get_in(assigns.payload, ["rawInput", "cwd"]) ||
          get_in(assigns.payload, ["_meta", "terminal_info", "cwd"])
      )
      |> assign(:status, assigns.payload["status"])

    ~H"""
    <div class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-zinc-950 px-2 py-1 text-xs font-semibold uppercase text-white">
          {tool_call_kind_label(@kind)}
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
      </div>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :if={@path} id="tool-call-path" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Path</dt>
          <dd class="truncate font-mono text-xs">{@path}</dd>
        </div>
        <div :if={@command} id="tool-call-command" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Command</dt>
          <dd class="truncate font-mono text-xs">{@command}</dd>
        </div>
        <div :if={@cwd} id="tool-call-cwd" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Working directory</dt>
          <dd class="truncate font-mono text-xs">{@cwd}</dd>
        </div>
        <div :if={@status} id="tool-call-status" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Status</dt>
          <dd class="font-mono text-xs">{@status}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp tool_call_update_event(assigns) do
    assigns =
      assigns
      |> assign(:title, assigns.payload["title"])
      |> assign(:status, assigns.payload["status"])
      |> assign(:exit_code, tool_call_exit_code(assigns.payload))
      |> assign(:output, tool_call_output(assigns.payload))

    ~H"""
    <div class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-emerald-700 px-2 py-1 text-xs font-semibold uppercase text-white">
          Tool result
        </span>
        <p class="font-semibold text-zinc-900">
          {tool_result_label(@status, @exit_code)}
        </p>
      </div>
      <p :if={@title} class="text-sm font-medium text-zinc-800">{@title}</p>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :if={@status} id="tool-result-status">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Status</dt>
          <dd class="font-mono text-xs">{@status}</dd>
        </div>
        <div :if={!is_nil(@exit_code)} id="tool-result-exit-code">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Exit code</dt>
          <dd class="font-mono text-xs">{@exit_code}</dd>
        </div>
      </dl>

      <pre
        :if={@output}
        id="tool-result-output"
        class="max-h-48 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
      ><%= @output %></pre>
    </div>
    """
  end

  defp event_kind("user_message"), do: "user"
  defp event_kind("agent_message_chunk"), do: "agent"

  defp event_kind(type)
       when type in ["tool_call", "tool_call_update", "plan_update", "agent_thought_redacted"] do
    "protocol"
  end

  defp event_kind("agent_update_ignored"), do: "protocol"

  defp event_kind(type)
       when type in [
              "permission_requested",
              "permission_resolved",
              "permission_resolution_ignored",
              "capability_policy_applied",
              "file_read_requested",
              "file_read_succeeded",
              "file_read_failed",
              "file_read_denied",
              "file_write_requested",
              "file_write_succeeded",
              "file_write_failed",
              "file_write_denied",
              "terminal_create_requested",
              "terminal_created",
              "terminal_create_denied",
              "terminal_create_failed",
              "terminal_wait_requested",
              "terminal_wait_succeeded",
              "terminal_wait_failed",
              "terminal_output_requested",
              "terminal_output_succeeded",
              "terminal_output_failed",
              "terminal_release_requested",
              "terminal_released",
              "terminal_release_failed",
              "terminal_kill_requested",
              "terminal_kill_succeeded",
              "terminal_kill_failed"
            ] do
    "client"
  end

  defp event_kind(type)
       when type in [
              "agent_process_started",
              "agent_process_exited",
              "agent_process_down",
              "agent_initialized",
              "agent_session_started",
              "agent_start_failed",
              "agent_protocol_failed"
            ] do
    "runtime"
  end

  defp event_kind(_type), do: "app"

  defp event_kind_label("user_message"), do: "User"
  defp event_kind_label("agent_message_chunk"), do: "Agent"

  defp event_kind_label(type) do
    case event_kind(type) do
      "app" -> "App"
      "client" -> "Client request"
      "protocol" -> "Protocol"
      "runtime" -> "Runtime"
      kind -> String.capitalize(kind)
    end
  end

  defp client_event_title(type) do
    cond do
      String.starts_with?(type, "file_read_") -> "Read file"
      String.starts_with?(type, "file_write_") -> "Write file"
      type == "terminal_created" -> "Create terminal"
      type == "terminal_released" -> "Release terminal"
      String.starts_with?(type, "terminal_create_") -> "Create terminal"
      String.starts_with?(type, "terminal_wait_") -> "Wait for terminal"
      String.starts_with?(type, "terminal_output_") -> "Read terminal output"
      String.starts_with?(type, "terminal_release_") -> "Release terminal"
      String.starts_with?(type, "terminal_kill_") -> "Kill terminal"
      true -> String.replace(type, "_", " ")
    end
  end

  defp client_event_tag(type) do
    cond do
      String.starts_with?(type, "file_") -> "File"
      String.starts_with?(type, "terminal_") -> "Terminal"
      true -> "Client"
    end
  end

  defp client_event_status(type) do
    cond do
      String.ends_with?(type, "_requested") -> "Requested"
      String.ends_with?(type, "_succeeded") -> "Succeeded"
      String.ends_with?(type, "_failed") -> "Failed"
      String.ends_with?(type, "_denied") -> "Denied"
      String.ends_with?(type, "_created") -> "Created"
      String.ends_with?(type, "_released") -> "Released"
      true -> "Recorded"
    end
  end

  defp client_event_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        status when status in ["Succeeded", "Created", "Released"] ->
          "border-emerald-200 bg-emerald-50 text-emerald-700"

        status when status in ["Failed", "Denied"] ->
          "border-rose-200 bg-rose-50 text-rose-700"

        "Requested" ->
          "border-amber-200 bg-amber-50 text-amber-700"

        _ ->
          "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp runtime_failure_title("agent_start_failed"), do: "Agent start failed"
  defp runtime_failure_title("agent_protocol_failed"), do: "Agent protocol failed"
  defp runtime_failure_title("agent_process_down"), do: "Agent process disconnected"
  defp runtime_failure_title(_type), do: "Runtime failure"

  defp runtime_failure_reason(%{"reason" => reason}) when reason not in [nil, ""] do
    format_client_value(reason)
  end

  defp runtime_failure_reason(%{"error" => error}) when error not in [nil, ""] do
    format_client_value(error)
  end

  defp runtime_failure_reason(_payload), do: "unknown runtime failure"

  defp runtime_failure_fields(type, payload) do
    [
      client_field("type", "Event", type),
      client_field("agent", "Agent", payload["agent"]),
      client_field("workspace", "Workspace", payload["workspace"]),
      client_field("executable", "Executable", payload["executable"]),
      client_field("cwd", "Working directory", payload["cwd"]),
      client_field("pid", "Process id", payload["pid"]),
      client_field("exit-status", "Exit status", payload["exit_status"]),
      client_field("line", "Line", payload["line"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp client_event_fields(type, payload) do
    [
      client_field("path", "Path", payload["path"]),
      client_field("resolved-path", "Resolved path", payload["resolved_path"]),
      client_field("command", "Command", payload["command"]),
      client_field("args", "Arguments", payload["args"]),
      client_field("cwd", "Working directory", payload["cwd"]),
      client_field("terminal-id", "Terminal id", payload["terminal_id"]),
      client_field("bytes", "Bytes", payload["bytes"]),
      client_field("exit-status", "Exit status", payload["exit_status"]),
      client_field("line", "Line", payload["line"]),
      client_field("limit", "Limit", payload["limit"])
    ]
    |> Enum.reject(&is_nil/1)
    |> then(fn fields ->
      if fields == [] and client_event_error(payload) == nil do
        [client_field("type", "Event", type)]
      else
        fields
      end
    end)
  end

  defp client_field(_id, _label, nil), do: nil
  defp client_field(_id, _label, ""), do: nil

  defp client_field(id, label, value),
    do: %{id: id, label: label, value: format_client_value(value)}

  defp format_client_value(value) when is_list(value), do: Enum.join(value, " ")
  defp format_client_value(value), do: to_string(value)

  defp workspace_name(nil), do: "No workspace"
  defp workspace_name(""), do: "No workspace"

  defp workspace_name(path) do
    case Path.basename(path) do
      "" -> path
      "/" -> path
      name -> name
    end
  end

  defp workspace_parent(nil), do: nil
  defp workspace_parent(""), do: nil

  defp workspace_parent(path) do
    parent = Path.dirname(path)

    if parent == path do
      nil
    else
      parent
    end
  end

  defp agent_readiness(agent) do
    File.cwd!()
    |> AgentProbe.agent_inventory()
    |> Enum.find(&(&1.agent == agent))
    |> case do
      nil -> %{}
      readiness -> readiness
    end
  end

  defp agent_evidence_label(_inventory, reports) when reports != [] do
    pluralize_count(length(reports), "accepted probe")
  end

  defp agent_evidence_label(%{real_agent_candidate: true}, _reports), do: "Static candidate"
  defp agent_evidence_label(%{status: "invalid"}, _reports), do: "Invalid command"
  defp agent_evidence_label(_inventory, _reports), do: "Local harness"

  defp agent_evidence_class(_inventory, reports) when reports != [] do
    badge_class("border-emerald-200 bg-emerald-50 text-emerald-700")
  end

  defp agent_evidence_class(%{real_agent_candidate: true}, _reports) do
    badge_class("border-sky-200 bg-sky-50 text-sky-700")
  end

  defp agent_evidence_class(%{status: "invalid"}, _reports) do
    badge_class("border-rose-200 bg-rose-50 text-rose-700")
  end

  defp agent_evidence_class(_inventory, _reports) do
    badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")
  end

  defp agent_evidence_reason(_inventory, reports) when reports != [] do
    "validated committed reports prove accepted real-agent evidence"
  end

  defp agent_evidence_reason(%{real_agent_rejection_reasons: []}, _reports) do
    "command resolves; not ACP evidence until preflight or a generated probe passes"
  end

  defp agent_evidence_reason(%{real_agent_rejection_reasons: reasons}, _reports)
       when is_list(reasons),
       do: Enum.join(reasons, "; ")

  defp agent_evidence_reason(_inventory, _reports), do: "agent readiness unknown"

  defp agent_probe_report_label(report) do
    report.path
    |> Path.relative_to(File.cwd!())
    |> then(fn path ->
      "#{path} · #{pluralize_count(length(report.expected_events), "event")} · #{pluralize_count(length(report.expected_event_fields), "field")}"
    end)
  end

  defp agent_launch_label(%{status: "ready"}), do: "Launch ready"
  defp agent_launch_label(%{status: "invalid"}), do: "Launch blocked"
  defp agent_launch_label(_inventory), do: "Launch unknown"

  defp agent_launch_class(%{status: "ready"}) do
    badge_class("border-emerald-200 bg-emerald-50 text-emerald-700")
  end

  defp agent_launch_class(%{status: "invalid"}) do
    badge_class("border-rose-200 bg-rose-50 text-rose-700")
  end

  defp agent_launch_class(_inventory) do
    badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")
  end

  defp badge_class(extra_class) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      extra_class
    ]
  end

  defp pluralize_count(1, singular), do: "1 #{singular}"
  defp pluralize_count(count, singular), do: "#{count} #{singular}s"

  defp client_event_error(payload) do
    case payload["error"] do
      %{"message" => message, "data" => %{"reason" => reason}} ->
        "#{message} (#{reason})"

      %{"message" => message} ->
        message

      _ ->
        nil
    end
  end

  defp tool_call_kind_label("read"), do: "File read"
  defp tool_call_kind_label("execute"), do: "Terminal"
  defp tool_call_kind_label(kind), do: String.replace(to_string(kind), "_", " ")

  defp tool_result_label("completed", 0), do: "Completed successfully"

  defp tool_result_label("completed", exit_code) when is_integer(exit_code),
    do: "Completed with exit #{exit_code}"

  defp tool_result_label(status, _exit_code) when is_binary(status), do: String.capitalize(status)
  defp tool_result_label(_status, _exit_code), do: "Tool result"

  defp tool_call_path(%{"locations" => [%{"path" => path} | _rest]}) when is_binary(path),
    do: path

  defp tool_call_path(_payload), do: nil

  defp tool_call_exit_code(payload) do
    get_in(payload, ["rawOutput", "exit_code"]) ||
      get_in(payload, ["_meta", "terminal_exit", "exit_code"])
  end

  defp tool_call_output(payload) do
    output =
      get_in(payload, ["rawOutput", "formatted_output"]) ||
        get_in(payload, ["_meta", "terminal_output_delta", "data"])

    if is_binary(output) and output != "" do
      String.slice(output, 0, 4_000)
    end
  end

  defp tool_call_id(payload) do
    payload["toolCallId"] || payload["tool_call_id"] || payload["id"]
  end

  defp permission_tool_call_id(permission) do
    tool_call = permission.payload["toolCall"] || %{}
    tool_call["toolCallId"] || tool_call["tool_call_id"] || tool_call["id"] || "unknown"
  end

  defp permission_tool_status(permission) do
    get_in(permission.payload, ["toolCall", "status"]) || "pending"
  end

  defp permission_option_label(option) do
    "#{option["name"]} (#{option["optionId"]})"
  end

  defp permission_decision_summary(permission) do
    raw_input = get_in(permission.payload, ["toolCall", "rawInput"]) || %{}
    title = get_in(permission.payload, ["toolCall", "title"]) || ""

    cond do
      raw_input["content_preview"] || raw_input["diff_preview"] ->
        %{
          action: "Review the proposed file change.",
          consequence: "Allow writes this content to the workspace; deny leaves files unchanged."
        }

      raw_input["command"] && is_nil(raw_input["content_preview"]) &&
          is_nil(raw_input["diff_preview"]) ->
        %{
          action: "Review the terminal command.",
          consequence:
            "Allow starts this process in the workspace; deny prevents it from running."
        }

      String.downcase(title) =~ "read file" ->
        %{
          action: "Review the requested file read.",
          consequence: "Allow sends the file contents to the agent; deny keeps them unavailable."
        }

      String.downcase(title) =~ "write file" ->
        %{
          action: "Review the requested file write.",
          consequence: "Allow lets the agent proceed with this write request; deny blocks it."
        }

      true ->
        %{
          action: "Review the requested agent action.",
          consequence: "Allow returns approval to the agent; deny blocks this action."
        }
    end
  end

  defp event_sequence_label(event, %{seq: result_seq}), do: "##{event.seq}-#{result_seq}"
  defp event_sequence_label(event, _result_event), do: "##{event.seq}"

  defp event_type_label(%{type: "tool_call"}, %{type: "tool_call_update"}),
    do: "tool_call + tool_call_update"

  defp event_type_label(event, _result_event), do: event.type

  defp event_card_class(kind) do
    [
      "rounded-2xl px-4 py-3 text-sm",
      case kind do
        "user" -> "ml-auto max-w-[88%] border border-zinc-200 bg-zinc-50"
        "agent" -> "mr-auto max-w-[88%] border border-zinc-200 bg-white"
        "client" -> "w-full border border-zinc-200 bg-white"
        "protocol" -> "w-full border border-zinc-200 bg-zinc-50"
        "runtime" -> "w-full border border-zinc-200 bg-zinc-50"
        _ -> "w-full border border-zinc-200 bg-white"
      end
    ]
  end

  defp event_kind_class(kind) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case kind do
        "user" -> "border-indigo-200 bg-indigo-50 text-indigo-700"
        "agent" -> "border-sky-200 bg-sky-50 text-sky-700"
        "client" -> "border-amber-200 bg-amber-50 text-amber-700"
        "protocol" -> "border-violet-200 bg-violet-50 text-violet-700"
        "runtime" -> "border-rose-200 bg-rose-50 text-rose-700"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp policy_label("allow"), do: "Allow"
  defp policy_label("deny"), do: "Deny"
  defp policy_label(_ask), do: "Ask"

  defp policy_scope_items(scopes) when is_list(scopes) and scopes != [], do: scopes
  defp policy_scope_items(_scopes), do: ["All workspace paths"]

  defp policy_scope_class(scopes) when is_list(scopes) and scopes != [] do
    "inline-flex max-w-full items-center rounded-md border border-zinc-200 bg-white px-2 py-0.5 text-[11px] font-medium text-zinc-700"
  end

  defp policy_scope_class(_scopes) do
    "inline-flex max-w-full items-center rounded-md border border-amber-200 bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-700"
  end

  defp policy_scope_id(scope) do
    scope
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "scope"
      id -> id
    end
  end

  defp policy_badge_class(decision) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case decision do
        "allow" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "deny" -> "border-rose-200 bg-rose-50 text-rose-700"
        _ask -> "border-amber-200 bg-amber-50 text-amber-700"
      end
    ]
  end

  defp permission_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        "pending" -> "border-amber-200 bg-amber-50 text-amber-700"
        "resolved" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "cancelled" -> "border-zinc-200 bg-zinc-50 text-zinc-600"
        "ignored" -> "border-violet-200 bg-violet-50 text-violet-700"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp permission_kind_label("agent_permission"), do: "Agent permission"
  defp permission_kind_label("file_read"), do: "File read"
  defp permission_kind_label("file_write"), do: "File write"
  defp permission_kind_label("terminal_create"), do: "Terminal create"
  defp permission_kind_label("resolution_attempt"), do: "Stale resolution"
  defp permission_kind_label(kind), do: kind || "Permission"

  defp permission_options_label(%{"items" => options}) when is_list(options) do
    options
    |> Enum.map(&(&1["optionId"] || &1["name"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      label -> label
    end
  end

  defp permission_options_label(_options), do: "none"

  defp permission_audit_for_event(audits, event) do
    request_id = to_string(event.payload["request_id"])

    Enum.find(audits, fn audit ->
      to_string(audit.request_id) == request_id
    end)
  end

  defp permission_resolution_title(
         %{type: "permission_resolution_ignored", payload: payload},
         _audit
       ) do
    "Stale decision ignored: #{payload["option_id"] || "unknown"}"
  end

  defp permission_resolution_title(%{payload: payload}, audit) do
    title =
      if audit do
        audit.title || permission_kind_label(audit.kind)
      else
        "permission request"
      end

    "Decision recorded: #{payload["option_id"] || "unknown"} for #{title}"
  end

  defp permission_resolution_status(%{type: "permission_resolution_ignored"}, _audit),
    do: "ignored"

  defp permission_resolution_status(_event, %{status: status}), do: status

  defp permission_resolution_status(%{payload: %{"outcome" => "cancelled"}}, _audit),
    do: "cancelled"

  defp permission_resolution_status(_event, _audit), do: "resolved"

  defp permission_resolution_fields(event, audit) do
    payload = event.payload

    [
      %{id: "request", label: "Request", value: payload["request_id"]},
      %{id: "selected", label: "Selected", value: payload["option_id"]},
      audit && %{id: "kind", label: "Kind", value: permission_kind_label(audit.kind)},
      audit && audit.tool_call_id &&
        %{id: "tool-call", label: "Tool call", value: audit.tool_call_id},
      %{id: "actor", label: "Actor", value: payload["actor"]},
      %{id: "outcome", label: "Outcome", value: payload["outcome"]},
      %{id: "reason", label: "Reason", value: payload["reason"]}
    ]
    |> Enum.reject(fn
      nil -> true
      %{value: nil} -> true
      %{value: ""} -> true
      _field -> false
    end)
  end

  defp terminal_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        "running" -> "border-sky-200 bg-sky-50 text-sky-700"
        "exited" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "killed" -> "border-rose-200 bg-rose-50 text-rose-700"
        "failed" -> "border-rose-200 bg-rose-50 text-rose-700"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp terminal_session_counts(sessions) do
    counts = Enum.frequencies_by(sessions, & &1.status)

    %{
      "all" => length(sessions),
      "running" => Map.get(counts, "running", 0),
      "completed" => Map.get(counts, "exited", 0) + Map.get(counts, "released", 0),
      "attention" => Map.get(counts, "killed", 0) + Map.get(counts, "failed", 0)
    }
  end

  defp terminal_review_label(%{status: "running"}), do: "Running"

  defp terminal_review_label(%{status: status}) when status in ["exited", "released"],
    do: "Completed"

  defp terminal_review_label(%{status: status}) when status in ["killed", "failed"],
    do: "Needs attention"

  defp terminal_review_label(_session), do: "Recorded"

  defp terminal_review_hint(%{status: "running"}) do
    "This terminal is still active or waiting for output."
  end

  defp terminal_review_hint(%{status: "exited", exit_status: 0}) do
    "The command exited successfully."
  end

  defp terminal_review_hint(%{status: "exited", exit_status: status}) when not is_nil(status) do
    "The command exited with status #{status}."
  end

  defp terminal_review_hint(%{status: "released"}) do
    "The terminal was released without a captured exit status."
  end

  defp terminal_review_hint(%{status: "killed"}) do
    "The terminal was killed before normal completion."
  end

  defp terminal_review_hint(%{status: "failed"}) do
    "Terminal execution failed; inspect the timeline for the failure event."
  end

  defp terminal_review_hint(_session), do: "This terminal session is recorded for review."

  defp terminal_args_label(%{"items" => []}), do: "none"
  defp terminal_args_label(%{"items" => args}) when is_list(args), do: Enum.join(args, " ")
  defp terminal_args_label(_args), do: "none"

  defp terminal_env_keys_label(%{"items" => []}), do: "none"
  defp terminal_env_keys_label(%{"items" => keys}) when is_list(keys), do: Enum.join(keys, ", ")
  defp terminal_env_keys_label(_keys), do: "none"

  defp terminal_exit_label(nil), do: "running"
  defp terminal_exit_label(status), do: to_string(status)

  defp terminal_output_preview(""), do: nil
  defp terminal_output_preview(nil), do: nil
  defp terminal_output_preview(preview), do: preview

  defp file_change_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        "pending" -> "border-amber-200 bg-amber-50 text-amber-700"
        "applied" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "denied" -> "border-rose-200 bg-rose-50 text-rose-700"
        "failed" -> "border-rose-200 bg-rose-50 text-rose-700"
        "cancelled" -> "border-zinc-200 bg-zinc-50 text-zinc-600"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp file_change_counts(changes) do
    counts = Enum.frequencies_by(changes, & &1.status)

    %{
      "all" => length(changes),
      "pending" => Map.get(counts, "pending", 0),
      "applied" => Map.get(counts, "applied", 0),
      "blocked" =>
        Enum.reduce(["denied", "failed", "cancelled"], 0, fn status, total ->
          total + Map.get(counts, status, 0)
        end)
    }
  end

  defp file_change_review_label(%{status: "pending"}), do: "Needs review"
  defp file_change_review_label(%{status: "applied"}), do: "Applied"

  defp file_change_review_label(%{status: status})
       when status in ["denied", "failed", "cancelled"],
       do: "Blocked"

  defp file_change_review_label(_change), do: "Recorded"

  defp file_change_review_hint(%{status: "pending"}) do
    "Review the proposed content and diff before deciding."
  end

  defp file_change_review_hint(%{status: "applied"}) do
    "This change was written to the workspace."
  end

  defp file_change_review_hint(%{status: "denied"}) do
    "This proposed change was denied and did not touch the workspace."
  end

  defp file_change_review_hint(%{status: "failed"}) do
    "This proposed change failed while applying."
  end

  defp file_change_review_hint(%{status: "cancelled"}) do
    "This proposed change was cancelled before completion."
  end

  defp file_change_review_hint(_change), do: "This file change is recorded for review."

  defp file_change_error(nil), do: nil

  defp file_change_error(%{"message" => message, "data" => %{"reason" => reason}}) do
    "#{message} (#{reason})"
  end

  defp file_change_error(%{"message" => message}), do: message
  defp file_change_error(_error), do: "File change failed"

  defp file_change_preview(""), do: nil
  defp file_change_preview(nil), do: nil
  defp file_change_preview(preview), do: preview

  defp proposed_file_change(%{payload: payload}) do
    raw_input = get_in(payload, ["toolCall", "rawInput"]) || %{}

    if raw_input["content_preview"] || raw_input["diff_preview"] do
      raw_input
    end
  end

  defp proposed_file_change(_permission), do: nil

  defp proposed_terminal_request(%{payload: payload}) do
    raw_input = get_in(payload, ["toolCall", "rawInput"]) || %{}

    if raw_input["command"] && is_nil(raw_input["content_preview"]) &&
         is_nil(raw_input["diff_preview"]) do
      raw_input
    end
  end

  defp proposed_terminal_request(_permission), do: nil

  defp terminal_request_args_label(args) when is_list(args) and args != [],
    do: Enum.join(args, " ")

  defp terminal_request_args_label(_args), do: "none"

  defp terminal_request_env_keys(nil), do: "none"
  defp terminal_request_env_keys(env) when env == %{}, do: "none"

  defp terminal_request_env_keys(env) when is_map(env) do
    env
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp terminal_request_env_keys(_env), do: "none"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="haven-run" class="min-h-dvh bg-white text-zinc-950">
        <section class="mx-auto grid max-w-6xl gap-4 px-4 py-4 md:px-8 md:py-6 lg:grid-cols-[minmax(0,1fr)_320px]">
          <div class="min-w-0 space-y-4">
            <header class="border-b border-zinc-200 pb-4">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <.link
                    navigate={~p"/"}
                    class="text-sm font-medium text-zinc-600 hover:text-zinc-950"
                  >
                    ← Inbox
                  </.link>
                  <h1 class="mt-2 truncate text-2xl font-semibold">{@run.title}</h1>
                  <p
                    id="run-header-workspace"
                    title={@run.workspace}
                    class="mt-1 flex min-w-0 items-center gap-1 truncate text-sm text-zinc-500"
                  >
                    <.icon name="hero-folder" class="size-4 shrink-0 text-zinc-400" />
                    <span class="truncate font-medium text-zinc-700">
                      {workspace_name(@run.workspace)}
                    </span>
                  </p>
                  <p
                    :if={workspace_parent(@run.workspace)}
                    id="run-header-workspace-path"
                    class="mt-0.5 truncate text-xs text-zinc-500"
                  >
                    {workspace_parent(@run.workspace)}
                  </p>
                  <dl
                    id="run-header-facts"
                    class="mt-3 grid gap-2 text-xs text-zinc-600 sm:grid-cols-2 lg:grid-cols-4"
                  >
                    <div id="run-header-agent" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Agent</dt>
                      <dd class="truncate font-mono">{@run.agent}</dd>
                      <dd class="mt-1 flex flex-wrap gap-1">
                        <span
                          id="run-header-agent-launch"
                          class={agent_launch_class(@agent_readiness)}
                        >
                          {agent_launch_label(@agent_readiness)}
                        </span>
                        <span
                          id="run-header-agent-trust"
                          class={agent_evidence_class(@agent_readiness, @agent_probe_reports)}
                        >
                          {agent_evidence_label(@agent_readiness, @agent_probe_reports)}
                        </span>
                      </dd>
                      <dd
                        id="run-header-agent-evidence-reason"
                        class="mt-1 truncate text-[11px] font-normal normal-case text-zinc-500"
                      >
                        {agent_evidence_reason(@agent_readiness, @agent_probe_reports)}
                      </dd>
                    </div>
                    <div id="run-header-session" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Session</dt>
                      <dd class="truncate font-mono">{@run.agent_session_id || "starting"}</dd>
                    </div>
                    <div id="run-header-created" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Created</dt>
                      <dd class="truncate font-mono">
                        {Calendar.strftime(@run.inserted_at, "%Y-%m-%d %H:%M:%S")}
                      </dd>
                    </div>
                    <div id="run-header-updated" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Updated</dt>
                      <dd class="truncate font-mono">
                        {Calendar.strftime(@run.updated_at, "%Y-%m-%d %H:%M:%S")}
                      </dd>
                    </div>
                  </dl>
                  <details
                    :if={@agent_probe_reports != []}
                    id="run-header-agent-probe-evidence"
                    class="mt-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-900"
                  >
                    <summary class="cursor-pointer font-semibold">
                      Accepted probe artifacts
                    </summary>
                    <ul class="mt-2 space-y-1">
                      <li
                        :for={report <- @agent_probe_reports}
                        id={"run-header-agent-probe-#{Path.basename(report.path, ".json")}"}
                        class="truncate"
                        title={report.prompt}
                      >
                        {agent_probe_report_label(report)}
                      </li>
                    </ul>
                  </details>
                </div>
                <span class="inline-flex shrink-0 items-center rounded-full border border-zinc-200 bg-white px-3 py-1 text-sm font-medium text-zinc-700">
                  {@run.status}
                </span>
              </div>
            </header>

            <section id="run-thread" class="flex flex-col gap-3">
              <section
                :if={@recovery_attention}
                id="run-recovery-card"
                class="rounded-2xl border border-rose-200 bg-rose-50 p-4"
              >
                <p class="text-xs font-semibold uppercase text-rose-700">Needs recovery</p>
                <h2 class="mt-1 text-base font-semibold text-zinc-950">
                  {@recovery_attention.title}
                </h2>
                <p class="mt-2 text-sm text-zinc-700">
                  {@recovery_attention.body}
                </p>
                <p
                  :if={@can_retry_last_prompt?}
                  id="retry-last-prompt-preview"
                  class="mt-3 line-clamp-3 rounded-md border border-rose-200 bg-white px-3 py-2 text-sm text-zinc-700"
                >
                  {@last_user_prompt}
                </p>
                <.form
                  :if={@can_continue_failed?}
                  id="continue-after-failure-form"
                  for={to_form(%{})}
                  phx-submit="continue_failed"
                  class="mt-3 space-y-2"
                >
                  <textarea
                    id="continue-after-failure-prompt"
                    name="prompt"
                    class="min-h-24 w-full rounded-md border border-rose-200 bg-white px-3 py-2 text-sm shadow-sm outline-none transition placeholder:text-zinc-400 focus:border-rose-700 focus:ring-2 focus:ring-rose-700/10"
                    placeholder="Continue with a new instruction"
                  ></textarea>
                  <button
                    id="continue-after-failure-button"
                    class="h-10 w-full rounded-md bg-rose-700 px-4 text-sm font-semibold text-white transition hover:bg-rose-800 sm:w-auto"
                  >
                    Continue with new prompt
                  </button>
                </.form>
                <div class="mt-3 flex flex-wrap gap-2">
                  <button
                    :if={@can_retry_last_prompt?}
                    id="retry-last-prompt-button"
                    type="button"
                    class="h-10 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800"
                    phx-click="retry_last_prompt"
                  >
                    Retry last prompt
                  </button>
                  <button
                    id="run-recovery-action-button"
                    type="button"
                    class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                    phx-click="reconnect"
                  >
                    {@recovery_attention.action}
                  </button>
                </div>
              </section>

              <section
                :if={@pending_permission}
                id="pending-permission-card"
                class="rounded-2xl border border-zinc-300 bg-white p-4"
              >
                <% decision_summary = permission_decision_summary(@pending_permission) %>
                <p class="text-xs font-semibold uppercase text-zinc-500">Needs approval</p>
                <h2 class="mt-1 text-base font-semibold text-zinc-950">
                  {get_in(@pending_permission.payload, ["toolCall", "title"]) || "Approve request?"}
                </h2>
                <p class="mt-2 text-sm text-zinc-600">
                  The agent is blocked until you choose an option.
                </p>
                <div
                  id="pending-permission-decision-summary"
                  class="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"
                >
                  <p id="pending-permission-decision-action" class="font-semibold">
                    {decision_summary.action}
                  </p>
                  <p id="pending-permission-decision-consequence" class="mt-1 text-amber-900">
                    {decision_summary.consequence}
                  </p>
                </div>
                <div id="pending-permission-primary-actions" class="mt-3 flex flex-wrap gap-2">
                  <button
                    :for={option <- @pending_permission.payload["options"]}
                    class={[
                      "h-10 rounded-md px-4 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-50",
                      if(String.starts_with?(option["kind"], "allow"),
                        do: "bg-zinc-950 text-white hover:bg-zinc-800",
                        else: "border border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50"
                      )
                    ]}
                    phx-click="resolve_permission"
                    phx-value-request-id={@pending_permission.payload["request_id"]}
                    phx-value-option-id={option["optionId"]}
                    disabled={!@live?}
                  >
                    {option["name"]}
                  </button>
                  <button
                    id="pending-permission-cancel-button"
                    type="button"
                    class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                    phx-click="cancel"
                    disabled={!@can_cancel?}
                  >
                    Cancel turn
                  </button>
                </div>
                <dl
                  id="pending-permission-authority"
                  class="mt-3 grid gap-2 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-700 sm:grid-cols-3"
                >
                  <div id="pending-permission-authority-read" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Reads</dt>
                    <dd class="mt-1 flex flex-wrap items-center gap-1">
                      <span class={policy_badge_class(@capability_policy["file_read"])}>
                        {policy_label(@capability_policy["file_read"])}
                      </span>
                      <span
                        :for={scope <- policy_scope_items(@capability_policy["file_read_paths"])}
                        id={"pending-permission-read-scope-#{policy_scope_id(scope)}"}
                        class={policy_scope_class(@capability_policy["file_read_paths"])}
                      >
                        <span class="truncate">{scope}</span>
                      </span>
                    </dd>
                  </div>
                  <div id="pending-permission-authority-write" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Writes</dt>
                    <dd class="mt-1 flex flex-wrap items-center gap-1">
                      <span class={policy_badge_class(@capability_policy["file_write"])}>
                        {policy_label(@capability_policy["file_write"])}
                      </span>
                      <span
                        :for={scope <- policy_scope_items(@capability_policy["file_write_paths"])}
                        id={"pending-permission-write-scope-#{policy_scope_id(scope)}"}
                        class={policy_scope_class(@capability_policy["file_write_paths"])}
                      >
                        <span class="truncate">{scope}</span>
                      </span>
                    </dd>
                  </div>
                  <div id="pending-permission-authority-terminal" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Terminals</dt>
                    <dd class="mt-1">
                      <span class={policy_badge_class(@capability_policy["terminal_create"])}>
                        {policy_label(@capability_policy["terminal_create"])}
                      </span>
                    </dd>
                  </div>
                </dl>
                <% proposed_change = proposed_file_change(@pending_permission) %>
                <section
                  :if={proposed_change}
                  id="pending-permission-proposed-file-change"
                  class="mt-3 rounded-lg border border-zinc-200 bg-white p-3"
                >
                  <div class="flex min-w-0 items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="text-xs font-semibold uppercase text-zinc-500">
                        Proposed file change
                      </p>
                      <p
                        id="pending-permission-proposed-file-path"
                        class="mt-1 truncate font-mono text-sm font-semibold text-zinc-950"
                      >
                        {proposed_change["path"]}
                      </p>
                    </div>
                    <span
                      id="pending-permission-proposed-file-kind"
                      class="inline-flex shrink-0 rounded-full border border-zinc-200 bg-zinc-50 px-2 py-0.5 text-[11px] font-semibold uppercase text-zinc-600"
                    >
                      {proposed_change["diff_kind"] || "unknown"}
                    </span>
                  </div>
                  <dl class="mt-3 grid gap-2 text-xs text-zinc-700 sm:grid-cols-3">
                    <div id="pending-permission-proposed-file-change-id">
                      <dt class="font-semibold uppercase text-zinc-500">Change</dt>
                      <dd class="break-all font-mono">{proposed_change["change_id"]}</dd>
                    </div>
                    <div id="pending-permission-proposed-file-bytes">
                      <dt class="font-semibold uppercase text-zinc-500">Bytes</dt>
                      <dd class="font-mono">{proposed_change["bytes"]}</dd>
                    </div>
                    <div id="pending-permission-proposed-file-existing-bytes">
                      <dt class="font-semibold uppercase text-zinc-500">Existing bytes</dt>
                      <dd class="font-mono">{proposed_change["existing_bytes"] || 0}</dd>
                    </div>
                  </dl>
                  <pre
                    :if={file_change_preview(proposed_change["content_preview"])}
                    id="pending-permission-proposed-file-content"
                    class="mt-3 max-h-32 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
                  ><%= proposed_change["content_preview"] %></pre>
                  <p
                    :if={proposed_change["content_truncated"]}
                    id="pending-permission-proposed-file-content-truncated"
                    class="mt-2 text-xs font-medium text-amber-700"
                  >
                    Content preview truncated.
                  </p>
                  <pre
                    :if={file_change_preview(proposed_change["diff_preview"])}
                    id="pending-permission-proposed-file-diff"
                    class="mt-3 max-h-40 overflow-auto rounded-md bg-white p-3 text-xs text-zinc-800 ring-1 ring-zinc-200"
                  ><%= proposed_change["diff_preview"] %></pre>
                  <p
                    :if={proposed_change["diff_truncated"]}
                    id="pending-permission-proposed-file-diff-truncated"
                    class="mt-2 text-xs font-medium text-amber-700"
                  >
                    Diff preview truncated.
                  </p>
                </section>
                <% proposed_terminal = proposed_terminal_request(@pending_permission) %>
                <section
                  :if={proposed_terminal}
                  id="pending-permission-proposed-terminal"
                  class="mt-3 rounded-lg border border-zinc-200 bg-white p-3"
                >
                  <p class="text-xs font-semibold uppercase text-zinc-500">
                    Proposed terminal
                  </p>
                  <p
                    id="pending-permission-proposed-terminal-command"
                    class="mt-1 break-all font-mono text-sm font-semibold text-zinc-950"
                  >
                    {proposed_terminal["command"]}
                  </p>
                  <dl class="mt-3 grid gap-2 text-xs text-zinc-700 sm:grid-cols-3">
                    <div id="pending-permission-proposed-terminal-args">
                      <dt class="font-semibold uppercase text-zinc-500">Args</dt>
                      <dd class="break-all font-mono">
                        {terminal_request_args_label(proposed_terminal["args"])}
                      </dd>
                    </div>
                    <div id="pending-permission-proposed-terminal-cwd">
                      <dt class="font-semibold uppercase text-zinc-500">Working directory</dt>
                      <dd class="break-all font-mono">
                        {proposed_terminal["cwd"] || @run.workspace}
                      </dd>
                    </div>
                    <div id="pending-permission-proposed-terminal-env">
                      <dt class="font-semibold uppercase text-zinc-500">Env keys</dt>
                      <dd class="break-all font-mono">
                        {terminal_request_env_keys(proposed_terminal["env"])}
                      </dd>
                    </div>
                  </dl>
                </section>
                <dl class="mt-3 grid gap-2 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-700 sm:grid-cols-2">
                  <div id="pending-permission-request-id" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Request</dt>
                    <dd class="truncate font-mono">{@pending_permission.payload["request_id"]}</dd>
                  </div>
                  <div id="pending-permission-tool-call-id" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Tool call</dt>
                    <dd class="truncate font-mono">{permission_tool_call_id(@pending_permission)}</dd>
                  </div>
                  <div id="pending-permission-tool-status" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Status</dt>
                    <dd class="truncate font-mono">{permission_tool_status(@pending_permission)}</dd>
                  </div>
                  <div id="pending-permission-options" class="min-w-0">
                    <dt class="font-semibold uppercase text-zinc-500">Options</dt>
                    <dd class="truncate font-mono">
                      {Enum.map_join(
                        @pending_permission.payload["options"] || [],
                        ", ",
                        &permission_option_label/1
                      )}
                    </dd>
                  </div>
                </dl>
                <details class="mt-3 rounded-md border border-zinc-200 px-3 py-2">
                  <summary class="cursor-pointer text-sm font-medium text-zinc-700">
                    Technical details
                  </summary>
                  <pre class="mt-2 max-h-40 overflow-auto rounded-md bg-zinc-50 p-3 text-xs text-zinc-700"><%= Jason.encode!(get_in(@pending_permission.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
                </details>
              </section>

              <section
                id="run-control-panel"
                class="sticky bottom-0 z-20 -mx-4 border-y border-zinc-200 bg-white/95 px-4 py-3 shadow-[0_-12px_28px_rgba(255,255,255,0.92)] backdrop-blur md:static md:mx-0 md:rounded-lg md:border md:p-4 md:shadow-none md:backdrop-blur-none"
              >
                <h2 class="font-semibold">Message</h2>
                <p
                  :if={@control_notice}
                  id="run-control-notice"
                  class="mt-2 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-600"
                >
                  {@control_notice}
                </p>
                <.form
                  id="run-prompt-form"
                  for={to_form(%{})}
                  phx-submit="send_prompt"
                  class="mt-3 space-y-2"
                >
                  <textarea
                    id="run-prompt"
                    name="prompt"
                    class="min-h-28 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm outline-none transition placeholder:text-zinc-400 focus:border-zinc-900 focus:ring-2 focus:ring-zinc-900/10 disabled:cursor-not-allowed disabled:bg-zinc-100 disabled:text-zinc-500"
                    placeholder="Prompt this run"
                    disabled={!@can_prompt?}
                    title={@prompt_disabled_reason}
                    aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                  >{@prompt}</textarea>
                  <div class="flex gap-2">
                    <button
                      id="send-prompt-button"
                      class="h-10 flex-1 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-50"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      Send
                    </button>
                    <button
                      id="cancel-run-button"
                      type="button"
                      class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="cancel"
                      disabled={!@can_cancel?}
                      title={@cancel_disabled_reason}
                      aria-describedby={if(@cancel_disabled_reason, do: "run-control-notice")}
                    >
                      Cancel
                    </button>
                  </div>
                </.form>
                <details
                  id="sample-prompts-disclosure"
                  class="mt-3 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2"
                >
                  <summary class="cursor-pointer text-sm font-medium text-zinc-700">
                    Developer samples
                  </summary>
                  <div id="sample-prompts" class="mt-3 grid grid-cols-2 gap-2">
                    <button
                      id="sample-echo-button"
                      class="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="sample_prompt"
                      phx-value-text="hello from LiveView"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      Echo
                    </button>
                    <button
                      id="sample-permission-button"
                      class="rounded-md bg-amber-500 px-3 py-1.5 text-sm font-semibold text-white transition hover:bg-amber-400 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="sample_prompt"
                      phx-value-text="permission"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      Ask permission
                    </button>
                    <button
                      id="sample-read-file-button"
                      class="rounded-md border border-sky-200 bg-sky-50 px-3 py-1.5 text-sm font-semibold text-sky-800 transition hover:bg-sky-100 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="sample_prompt"
                      phx-value-text="read-file"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      Read file
                    </button>
                    <button
                      id="sample-write-file-button"
                      class="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-sm font-semibold text-emerald-800 transition hover:bg-emerald-100 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="sample_prompt"
                      phx-value-text="write-file"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      Write file
                    </button>
                    <button
                      id="sample-terminal-button"
                      class="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="sample_prompt"
                      phx-value-text="terminal"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      Terminal
                    </button>
                  </div>
                </details>
              </section>

              <details id="timeline-filters" class="rounded-lg border border-zinc-200 bg-white p-3">
                <summary class="cursor-pointer text-sm font-medium text-zinc-700">
                  Filter activity
                </summary>
                <form
                  id="timeline-search-form"
                  phx-change="search_events"
                  phx-submit="search_events"
                  class="mt-3 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]"
                >
                  <.input
                    id="event_search"
                    name="event_search"
                    value={@event_search}
                    type="search"
                    label="Search activity"
                    placeholder="Event type, tool id, path, command, output"
                    autocomplete="off"
                  />
                  <button
                    :if={@event_search != ""}
                    id="clear-timeline-search"
                    type="button"
                    class="mb-2 h-10 self-end rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                    phx-click="clear_event_search"
                  >
                    Clear
                  </button>
                </form>
                <div class="mt-3 flex flex-wrap items-center gap-2">
                  <button
                    :for={{kind, label} <- @event_filters}
                    id={"timeline-filter-#{kind}"}
                    type="button"
                    phx-click="filter_events"
                    phx-value-kind={kind}
                    class={[
                      "inline-flex h-8 items-center rounded-md border px-3 text-xs font-semibold transition",
                      @event_filter == kind &&
                        "border-zinc-950 bg-zinc-950 text-white",
                      @event_filter != kind &&
                        "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50"
                    ]}
                  >
                    {label}
                    <span class="ml-1 text-[11px] opacity-70">
                      {Map.get(@event_counts, kind, 0)}
                    </span>
                  </button>
                </div>
              </details>
              <div
                :if={@timeline_entries == []}
                id="timeline-empty-filter"
                class="rounded-lg border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"
              >
                <%= if @event_search != "" do %>
                  No events match this search.
                <% else %>
                  No events match this filter.
                <% end %>
              </div>
              <.event
                :for={entry <- @timeline_entries}
                event={entry.event}
                result_event={entry.result_event}
                permission_audits={@permission_audits}
              />
            </section>
          </div>

          <aside class="min-w-0 space-y-4">
            <section class="rounded-lg border border-zinc-200 bg-white p-4 text-sm shadow-sm">
              <h2 class="font-semibold">Run facts</h2>
              <dl class="mt-3 space-y-2">
                <div>
                  <dt class="text-zinc-500">Agent</dt>
                  <dd>{@run.agent}</dd>
                </div>
                <div>
                  <dt class="text-zinc-500">Agent session</dt>
                  <dd class="break-all">{@run.agent_session_id || "starting"}</dd>
                </div>
                <div>
                  <dt class="text-zinc-500">Process</dt>
                  <dd>{if @live?, do: "connected", else: "not connected"}</dd>
                </div>
              </dl>
              <details id="run-capability-policy" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>Capability policy</span>
                  <span class="normal-case text-zinc-400">
                    {policy_label(@capability_policy["file_read"])} reads
                  </span>
                </summary>
                <dl class="mt-2 grid gap-2">
                  <div id="run-policy-file-read" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">File reads</dt>
                    <dd class={policy_badge_class(@capability_policy["file_read"])}>
                      {policy_label(@capability_policy["file_read"])}
                    </dd>
                  </div>
                  <div id="run-policy-file-read-paths" class="grid gap-1">
                    <dt class="text-zinc-500">Read paths</dt>
                    <dd class="flex flex-wrap gap-1">
                      <span
                        :for={scope <- policy_scope_items(@capability_policy["file_read_paths"])}
                        id={"run-policy-file-read-scope-#{policy_scope_id(scope)}"}
                        class={policy_scope_class(@capability_policy["file_read_paths"])}
                      >
                        <span class="truncate">{scope}</span>
                      </span>
                    </dd>
                  </div>
                  <div id="run-policy-file-write" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">File writes</dt>
                    <dd class={policy_badge_class(@capability_policy["file_write"])}>
                      {policy_label(@capability_policy["file_write"])}
                    </dd>
                  </div>
                  <div id="run-policy-file-write-paths" class="grid gap-1">
                    <dt class="text-zinc-500">Write paths</dt>
                    <dd class="flex flex-wrap gap-1">
                      <span
                        :for={scope <- policy_scope_items(@capability_policy["file_write_paths"])}
                        id={"run-policy-file-write-scope-#{policy_scope_id(scope)}"}
                        class={policy_scope_class(@capability_policy["file_write_paths"])}
                      >
                        <span class="truncate">{scope}</span>
                      </span>
                    </dd>
                  </div>
                  <div id="run-policy-terminal-create" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">Terminals</dt>
                    <dd class={policy_badge_class(@capability_policy["terminal_create"])}>
                      {policy_label(@capability_policy["terminal_create"])}
                    </dd>
                  </div>
                </dl>
              </details>
              <details id="run-permission-audit" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>Permission audit</span>
                  <span
                    id="run-permission-audit-count"
                    class="font-mono text-xs text-zinc-500"
                  >
                    {length(@permission_audits)}
                  </span>
                </summary>

                <div
                  :if={@permission_audits == []}
                  id="run-permission-audit-empty"
                  class="mt-2 rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500"
                >
                  No permission decisions recorded.
                </div>

                <div class="mt-3 space-y-3">
                  <article
                    :for={audit <- @permission_audits}
                    id={"permission-audit-#{audit.id}"}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate text-xs font-semibold text-zinc-900">
                          {audit.title || permission_kind_label(audit.kind)}
                        </p>
                        <p class="mt-1 font-mono text-[11px] text-zinc-500">
                          request {audit.request_id}
                        </p>
                      </div>
                      <span
                        id={"permission-audit-#{audit.id}-status"}
                        class={permission_status_class(audit.status)}
                      >
                        {audit.status}
                      </span>
                    </div>

                    <dl class="mt-3 grid gap-2 text-xs text-zinc-700">
                      <div id={"permission-audit-#{audit.id}-kind"}>
                        <dt class="font-semibold uppercase text-zinc-500">Kind</dt>
                        <dd>{permission_kind_label(audit.kind)}</dd>
                      </div>
                      <div
                        :if={audit.tool_call_id}
                        id={"permission-audit-#{audit.id}-tool-call"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Tool call</dt>
                        <dd class="break-all font-mono">{audit.tool_call_id}</dd>
                      </div>
                      <div id={"permission-audit-#{audit.id}-options"}>
                        <dt class="font-semibold uppercase text-zinc-500">Options</dt>
                        <dd class="break-all font-mono">{permission_options_label(audit.options)}</dd>
                      </div>
                      <div
                        :if={audit.selected_option_id}
                        id={"permission-audit-#{audit.id}-selected-option"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Selected</dt>
                        <dd class="font-mono">{audit.selected_option_id}</dd>
                      </div>
                      <div :if={audit.actor} id={"permission-audit-#{audit.id}-actor"}>
                        <dt class="font-semibold uppercase text-zinc-500">Actor</dt>
                        <dd class="font-mono">{audit.actor}</dd>
                      </div>
                      <div :if={audit.reason} id={"permission-audit-#{audit.id}-reason"}>
                        <dt class="font-semibold uppercase text-zinc-500">Reason</dt>
                        <dd class="break-all font-mono">{audit.reason}</dd>
                      </div>
                    </dl>

                    <pre
                      :if={audit.raw_input && audit.raw_input != %{}}
                      id={"permission-audit-#{audit.id}-raw-input"}
                      class="mt-3 max-h-32 overflow-auto rounded-md bg-white p-3 text-xs text-zinc-800 ring-1 ring-zinc-200"
                    ><%= Jason.encode!(audit.raw_input, pretty: true) %></pre>
                  </article>
                </div>
              </details>
              <details id="run-file-changes" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>File changes</span>
                  <span id="run-file-change-count" class="font-mono text-xs text-zinc-500">
                    {length(@file_changes)}
                  </span>
                </summary>

                <div
                  :if={@file_changes == []}
                  id="run-file-changes-empty"
                  class="mt-2 rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500"
                >
                  No file changes recorded.
                </div>

                <div
                  :if={@file_changes != []}
                  id="run-file-change-review-summary"
                  class="mt-3 grid grid-cols-3 gap-2 text-xs"
                >
                  <div class="rounded-md border border-amber-200 bg-amber-50 p-2">
                    <p class="font-semibold uppercase text-amber-700">Needs review</p>
                    <p id="run-file-change-pending-count" class="mt-1 font-mono text-zinc-900">
                      {@file_change_counts["pending"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-emerald-200 bg-emerald-50 p-2">
                    <p class="font-semibold uppercase text-emerald-700">Applied</p>
                    <p id="run-file-change-applied-count" class="mt-1 font-mono text-zinc-900">
                      {@file_change_counts["applied"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-rose-200 bg-rose-50 p-2">
                    <p class="font-semibold uppercase text-rose-700">Blocked</p>
                    <p id="run-file-change-blocked-count" class="mt-1 font-mono text-zinc-900">
                      {@file_change_counts["blocked"]}
                    </p>
                  </div>
                </div>

                <div class="mt-3 space-y-3">
                  <article
                    :for={change <- @file_changes}
                    id={"file-change-#{change.change_id}"}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate font-mono text-xs font-semibold text-zinc-900">
                          {change.path}
                        </p>
                        <p class="mt-1 font-mono text-[11px] text-zinc-500">
                          {change.diff_kind}
                        </p>
                      </div>
                      <span
                        id={"file-change-#{change.change_id}-status"}
                        class={file_change_status_class(change.status)}
                      >
                        {change.status}
                      </span>
                    </div>
                    <p
                      id={"file-change-#{change.change_id}-review-state"}
                      class="mt-3 rounded-md border border-zinc-200 bg-white px-3 py-2 text-xs text-zinc-600"
                    >
                      <span class="font-semibold text-zinc-900">
                        {file_change_review_label(change)}
                      </span>
                      {" · "}{file_change_review_hint(change)}
                    </p>

                    <dl class="mt-3 grid gap-2 text-xs text-zinc-700">
                      <div
                        :if={change.resolved_path}
                        id={"file-change-#{change.change_id}-resolved-path"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Resolved path</dt>
                        <dd class="break-all font-mono">{change.resolved_path}</dd>
                      </div>
                      <div id={"file-change-#{change.change_id}-bytes"}>
                        <dt class="font-semibold uppercase text-zinc-500">Bytes</dt>
                        <dd class="font-mono">{change.bytes}</dd>
                      </div>
                      <div id={"file-change-#{change.change_id}-existing-bytes"}>
                        <dt class="font-semibold uppercase text-zinc-500">Existing bytes</dt>
                        <dd class="font-mono">{change.existing_bytes || 0}</dd>
                      </div>
                    </dl>

                    <p
                      :if={file_change_error(change.error)}
                      id={"file-change-#{change.change_id}-error"}
                      class="mt-3 text-xs font-medium text-rose-700"
                    >
                      {file_change_error(change.error)}
                    </p>

                    <pre
                      :if={file_change_preview(change.content_preview)}
                      id={"file-change-#{change.change_id}-content"}
                      class="mt-3 max-h-32 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
                    ><%= change.content_preview %></pre>
                    <p
                      :if={change.content_truncated}
                      id={"file-change-#{change.change_id}-content-truncated"}
                      class="mt-2 text-xs font-medium text-amber-700"
                    >
                      Content preview truncated.
                    </p>

                    <pre
                      :if={file_change_preview(change.diff_preview)}
                      id={"file-change-#{change.change_id}-diff"}
                      class="mt-3 max-h-40 overflow-auto rounded-md bg-white p-3 text-xs text-zinc-800 ring-1 ring-zinc-200"
                    ><%= change.diff_preview %></pre>
                    <p
                      :if={change.diff_truncated}
                      id={"file-change-#{change.change_id}-diff-truncated"}
                      class="mt-2 text-xs font-medium text-amber-700"
                    >
                      Diff preview truncated.
                    </p>
                  </article>
                </div>
              </details>
              <details id="run-terminal-sessions" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>Terminal sessions</span>
                  <span
                    id="run-terminal-session-count"
                    class="font-mono text-xs text-zinc-500"
                  >
                    {length(@terminal_sessions)}
                  </span>
                </summary>

                <div
                  :if={@terminal_sessions == []}
                  id="run-terminal-sessions-empty"
                  class="mt-2 rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500"
                >
                  No terminal sessions recorded.
                </div>

                <div
                  :if={@terminal_sessions != []}
                  id="run-terminal-session-summary"
                  class="mt-3 grid grid-cols-3 gap-2 text-xs"
                >
                  <div class="rounded-md border border-sky-200 bg-sky-50 p-2">
                    <p class="font-semibold uppercase text-sky-700">Running</p>
                    <p id="run-terminal-session-running-count" class="mt-1 font-mono text-zinc-900">
                      {@terminal_session_counts["running"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-emerald-200 bg-emerald-50 p-2">
                    <p class="font-semibold uppercase text-emerald-700">Completed</p>
                    <p id="run-terminal-session-completed-count" class="mt-1 font-mono text-zinc-900">
                      {@terminal_session_counts["completed"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-rose-200 bg-rose-50 p-2">
                    <p class="font-semibold uppercase text-rose-700">Needs attention</p>
                    <p id="run-terminal-session-attention-count" class="mt-1 font-mono text-zinc-900">
                      {@terminal_session_counts["attention"]}
                    </p>
                  </div>
                </div>

                <div class="mt-3 space-y-3">
                  <article
                    :for={session <- @terminal_sessions}
                    id={"terminal-session-#{session.terminal_id}"}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate font-mono text-xs font-semibold text-zinc-900">
                          {session.command}
                        </p>
                        <p class="mt-1 break-all font-mono text-[11px] text-zinc-500">
                          {session.terminal_id}
                        </p>
                      </div>
                      <span
                        id={"terminal-session-#{session.terminal_id}-status"}
                        class={terminal_status_class(session.status)}
                      >
                        {session.status}
                      </span>
                    </div>
                    <p
                      id={"terminal-session-#{session.terminal_id}-review-state"}
                      class="mt-3 rounded-md border border-zinc-200 bg-white px-3 py-2 text-xs text-zinc-600"
                    >
                      <span class="font-semibold text-zinc-900">
                        {terminal_review_label(session)}
                      </span>
                      {" · "}{terminal_review_hint(session)}
                    </p>

                    <dl class="mt-3 grid gap-2 text-xs text-zinc-700">
                      <div id={"terminal-session-#{session.terminal_id}-args"}>
                        <dt class="font-semibold uppercase text-zinc-500">Arguments</dt>
                        <dd class="break-all font-mono">{terminal_args_label(session.args)}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-cwd"}>
                        <dt class="font-semibold uppercase text-zinc-500">Working directory</dt>
                        <dd class="break-all font-mono">{session.cwd}</dd>
                      </div>
                      <div
                        :if={session.executable}
                        id={"terminal-session-#{session.terminal_id}-executable"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Executable</dt>
                        <dd class="break-all font-mono">{session.executable}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-exit"}>
                        <dt class="font-semibold uppercase text-zinc-500">Exit status</dt>
                        <dd class="font-mono">{terminal_exit_label(session.exit_status)}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-bytes"}>
                        <dt class="font-semibold uppercase text-zinc-500">Output bytes</dt>
                        <dd class="font-mono">{session.output_bytes}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-env"}>
                        <dt class="font-semibold uppercase text-zinc-500">Env keys</dt>
                        <dd class="break-all font-mono">
                          {terminal_env_keys_label(session.env_keys)}
                        </dd>
                      </div>
                    </dl>

                    <pre
                      :if={terminal_output_preview(session.output_preview)}
                      id={"terminal-session-#{session.terminal_id}-output"}
                      class="mt-3 max-h-32 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
                    ><%= session.output_preview %></pre>
                    <p
                      :if={session.output_truncated}
                      id={"terminal-session-#{session.terminal_id}-truncated"}
                      class="mt-2 text-xs font-medium text-amber-700"
                    >
                      Output preview truncated.
                    </p>
                  </article>
                </div>
              </details>
              <button
                :if={@can_reconnect?}
                id="reconnect-run-button"
                type="button"
                class="mt-4 h-10 w-full rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800"
                phx-click="reconnect"
              >
                {if @run.status == "failed", do: "Restart", else: "Reconnect"}
              </button>
            </section>
          </aside>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
