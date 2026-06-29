defmodule HavenWeb.RunLive do
  use HavenWeb, :live_view

  alias Haven.Events
  alias Haven.Runs
  alias Haven.Runs.Run

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

  def handle_event("filter_events", %{"kind" => kind}, socket) do
    kind = if valid_event_filter?(kind), do: kind, else: "all"

    {:noreply,
     socket
     |> assign(:event_filter, kind)
     |> assign_event_projection(socket.assigns.events)}
  end

  @impl true
  def handle_info({:event_appended, _event}, socket) do
    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_info({:run_updated, %{id: id}}, %{assigns: %{run: %{id: id}}} = socket) do
    {:noreply, assign_run(socket, id)}
  end

  def handle_info({:run_updated, _run}, socket), do: {:noreply, socket}

  defp assign_run(socket, id) do
    run = Runs.get_run!(id)
    events = Events.list_for_run(id)
    live? = Runs.started?(id)

    socket
    |> assign(:run, run)
    |> assign(:capability_policy, Run.capability_policy(run.capability_policy))
    |> assign(:events, events)
    |> assign_event_projection(events)
    |> assign(:live?, live?)
    |> assign(:can_prompt?, live? and run.status == "idle")
    |> assign(:can_cancel?, live? and run.status in ["initializing", "running", "waiting"])
    |> assign(:can_reconnect?, can_reconnect?(run, live?))
    |> assign(:pending_permission, latest_pending_permission(events))
  end

  defp assign_event_projection(socket, events) do
    filter = socket.assigns[:event_filter] || "all"

    socket
    |> assign(:event_filters, @event_filters)
    |> assign(:event_counts, event_counts(events))
    |> assign(:filtered_events, filter_events(events, filter))
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

  defp can_reconnect?(run, live?) do
    run.status == "failed" or (not live? and run.status != "closed")
  end

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

  defp event(assigns) do
    assigns =
      assigns
      |> assign(:event_kind, event_kind(assigns.event.type))
      |> assign(:event_kind_label, event_kind_label(assigns.event.type))

    ~H"""
    <article
      id={"event-#{@event.seq}"}
      data-event-kind={@event_kind}
      class={event_card_class(@event_kind)}
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <span class="font-mono text-xs uppercase text-zinc-500">
            #{@event.seq} · {@event.type}
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
          <% "permission_requested" -> %>
            <p class="font-semibold">
              {get_in(@event.payload, ["toolCall", "title"]) || "Permission requested"}
            </p>
            <pre class="mt-2 overflow-x-auto rounded-md bg-zinc-100 p-3 text-xs text-zinc-700"><%= Jason.encode!(get_in(@event.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
          <% _ -> %>
            <pre class="overflow-x-auto rounded-md bg-zinc-100 p-3 text-xs text-zinc-700"><%= Jason.encode!(@event.payload, pretty: true) %></pre>
        <% end %>
      </div>
    </article>
    """
  end

  defp event_kind("user_message"), do: "user"
  defp event_kind("agent_message_chunk"), do: "agent"

  defp event_kind(type) when type in ["tool_call_update", "plan_update"] do
    "protocol"
  end

  defp event_kind("agent_update_ignored"), do: "protocol"

  defp event_kind(type)
       when type in [
              "permission_requested",
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

  defp event_card_class(kind) do
    [
      "rounded-lg border bg-white p-4 shadow-sm",
      case kind do
        "user" -> "border-indigo-200"
        "agent" -> "border-sky-200"
        "client" -> "border-amber-200"
        "protocol" -> "border-violet-200"
        "runtime" -> "border-rose-200"
        _ -> "border-zinc-200"
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

  defp policy_scope_label(scopes) when is_list(scopes) and scopes != [],
    do: Enum.join(scopes, ", ")

  defp policy_scope_label(_scopes), do: "All workspace paths"

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="haven-run" class="min-h-dvh bg-zinc-100 text-zinc-950">
        <section class="mx-auto grid max-w-6xl gap-4 p-4 md:grid-cols-[1fr_320px] md:p-8">
          <div class="space-y-4">
            <header class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <.link
                    navigate={~p"/"}
                    class="text-sm font-medium text-zinc-600 hover:text-zinc-950"
                  >
                    ← Inbox
                  </.link>
                  <h1 class="mt-2 truncate text-2xl font-bold">{@run.title}</h1>
                  <p class="mt-1 truncate text-sm text-zinc-500">{@run.workspace}</p>
                </div>
                <span class="inline-flex shrink-0 items-center rounded-full border border-zinc-200 bg-white px-3 py-1 text-sm font-medium text-zinc-700">
                  {@run.status}
                </span>
              </div>
            </header>

            <section class="space-y-3">
              <div
                id="timeline-filters"
                class="flex flex-wrap items-center gap-2 rounded-lg border border-zinc-200 bg-white p-3 shadow-sm"
              >
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
              <div
                :if={@filtered_events == []}
                id="timeline-empty-filter"
                class="rounded-lg border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"
              >
                No events match this filter.
              </div>
              <.event :for={event <- @filtered_events} event={event} />
            </section>
          </div>

          <aside class="space-y-4">
            <section
              :if={@pending_permission}
              id="pending-permission-card"
              class="rounded-lg border border-amber-200 bg-amber-50 p-4 shadow-sm"
            >
              <h2 class="font-semibold text-amber-800">Needs approval</h2>
              <p class="mt-2 text-sm">{get_in(@pending_permission.payload, ["toolCall", "title"])}</p>
              <pre class="mt-2 overflow-x-auto rounded-md bg-white p-3 text-xs text-zinc-700"><%= Jason.encode!(get_in(@pending_permission.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
              <div class="mt-3 flex gap-2">
                <button
                  :for={option <- @pending_permission.payload["options"]}
                  class={
                    if String.starts_with?(option["kind"], "allow"),
                      do:
                        "rounded-md bg-emerald-600 px-3 py-1.5 text-sm font-semibold text-white transition hover:bg-emerald-500",
                      else:
                        "rounded-md bg-rose-600 px-3 py-1.5 text-sm font-semibold text-white transition hover:bg-rose-500"
                  }
                  phx-click="resolve_permission"
                  phx-value-request-id={@pending_permission.payload["request_id"]}
                  phx-value-option-id={option["optionId"]}
                  disabled={!@live?}
                >
                  {option["name"]}
                </button>
              </div>
            </section>

            <section class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
              <h2 class="font-semibold">Control</h2>
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
                >{@prompt}</textarea>
                <div class="flex gap-2">
                  <button
                    id="send-prompt-button"
                    class="h-10 flex-1 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-50"
                    disabled={!@can_prompt?}
                  >
                    Send
                  </button>
                  <button
                    id="cancel-run-button"
                    type="button"
                    class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                    phx-click="cancel"
                    disabled={!@can_cancel?}
                  >
                    Cancel
                  </button>
                </div>
              </.form>
              <div class="mt-3 grid grid-cols-2 gap-2">
                <button
                  id="sample-echo-button"
                  class="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="sample_prompt"
                  phx-value-text="hello from LiveView"
                  disabled={!@can_prompt?}
                >
                  Echo
                </button>
                <button
                  id="sample-permission-button"
                  class="rounded-md bg-amber-500 px-3 py-1.5 text-sm font-semibold text-white transition hover:bg-amber-400 disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="sample_prompt"
                  phx-value-text="permission"
                  disabled={!@can_prompt?}
                >
                  Ask permission
                </button>
                <button
                  id="sample-read-file-button"
                  class="rounded-md border border-sky-200 bg-sky-50 px-3 py-1.5 text-sm font-semibold text-sky-800 transition hover:bg-sky-100 disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="sample_prompt"
                  phx-value-text="read-file"
                  disabled={!@can_prompt?}
                >
                  Read file
                </button>
                <button
                  id="sample-write-file-button"
                  class="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-sm font-semibold text-emerald-800 transition hover:bg-emerald-100 disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="sample_prompt"
                  phx-value-text="write-file"
                  disabled={!@can_prompt?}
                >
                  Write file
                </button>
                <button
                  id="sample-terminal-button"
                  class="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="sample_prompt"
                  phx-value-text="terminal"
                  disabled={!@can_prompt?}
                >
                  Terminal
                </button>
              </div>
            </section>

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
              <div id="run-capability-policy" class="mt-4 border-t border-zinc-200 pt-4">
                <h3 class="text-xs font-semibold uppercase text-zinc-500">Capability policy</h3>
                <dl class="mt-2 grid gap-2">
                  <div id="run-policy-file-read" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">File reads</dt>
                    <dd class={policy_badge_class(@capability_policy["file_read"])}>
                      {policy_label(@capability_policy["file_read"])}
                    </dd>
                  </div>
                  <div id="run-policy-file-read-paths" class="grid gap-1">
                    <dt class="text-zinc-500">Read paths</dt>
                    <dd class="break-all text-zinc-700">
                      {policy_scope_label(@capability_policy["file_read_paths"])}
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
                    <dd class="break-all text-zinc-700">
                      {policy_scope_label(@capability_policy["file_write_paths"])}
                    </dd>
                  </div>
                  <div id="run-policy-terminal-create" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">Terminals</dt>
                    <dd class={policy_badge_class(@capability_policy["terminal_create"])}>
                      {policy_label(@capability_policy["terminal_create"])}
                    </dd>
                  </div>
                </dl>
              </div>
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
