defmodule HavenWeb.RunLive do
  use HavenWeb, :live_view

  alias Haven.Events
  alias Haven.Runs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Events.subscribe(id)
      Runs.ensure_started(id)
    end

    {:ok,
     socket
     |> assign(:prompt, "")
     |> assign_run(id)}
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)
    if prompt != "", do: Runs.send_prompt(socket.assigns.run.id, prompt)
    {:noreply, assign(socket, :prompt, "") |> assign_run(socket.assigns.run.id)}
  end

  def handle_event("sample_prompt", %{"text" => text}, socket) do
    Runs.send_prompt(socket.assigns.run.id, text)
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
    Runs.cancel(socket.assigns.run.id)
    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  @impl true
  def handle_info({:event_appended, _event}, socket) do
    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  defp assign_run(socket, id) do
    run = Runs.get_run!(id)
    events = Events.list_for_run(id)

    socket
    |> assign(:run, run)
    |> assign(:events, events)
    |> assign(:pending_permission, latest_pending_permission(events))
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
    ~H"""
    <article class="rounded border border-base-300 bg-base-100 p-4">
      <div class="flex items-center justify-between gap-3">
        <span class="font-mono text-xs uppercase text-base-content/50">
          #{@event.seq} · {@event.type}
        </span>
        <span class="text-xs text-base-content/40">
          {Calendar.strftime(@event.inserted_at, "%H:%M:%S")}
        </span>
      </div>

      <div class="mt-2">
        <%= case @event.type do %>
          <% "user_message" -> %>
            <p class="whitespace-pre-wrap">{@event.payload["text"]}</p>
          <% "agent_message_chunk" -> %>
            <p class="whitespace-pre-wrap text-info-content">{@event.payload["text"]}</p>
          <% "permission_requested" -> %>
            <p class="font-semibold">
              {get_in(@event.payload, ["toolCall", "title"]) || "Permission requested"}
            </p>
            <pre class="mt-2 overflow-x-auto rounded bg-base-200 p-3 text-xs"><%= Jason.encode!(get_in(@event.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
          <% _ -> %>
            <pre class="overflow-x-auto rounded bg-base-200 p-3 text-xs"><%= Jason.encode!(@event.payload, pretty: true) %></pre>
        <% end %>
      </div>
    </article>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-base-200">
      <section class="mx-auto grid max-w-6xl gap-4 p-4 md:grid-cols-[1fr_320px] md:p-8">
        <div class="space-y-4">
          <header class="rounded border border-base-300 bg-base-100 p-4">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <.link navigate={~p"/"} class="text-sm text-primary">← Inbox</.link>
                <h1 class="mt-2 truncate text-2xl font-bold">{@run.title}</h1>
                <p class="mt-1 truncate text-sm text-base-content/60">{@run.workspace}</p>
              </div>
              <span class="badge badge-lg">{@run.status}</span>
            </div>
          </header>

          <section class="space-y-3">
            <.event :for={event <- @events} event={event} />
          </section>
        </div>

        <aside class="space-y-4">
          <section :if={@pending_permission} class="rounded border border-warning bg-warning/10 p-4">
            <h2 class="font-semibold text-warning">Needs approval</h2>
            <p class="mt-2 text-sm">{get_in(@pending_permission.payload, ["toolCall", "title"])}</p>
            <pre class="mt-2 overflow-x-auto rounded bg-base-100 p-3 text-xs"><%= Jason.encode!(get_in(@pending_permission.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
            <div class="mt-3 flex gap-2">
              <button
                :for={option <- @pending_permission.payload["options"]}
                class={
                  if String.starts_with?(option["kind"], "allow"),
                    do: "btn btn-sm btn-success",
                    else: "btn btn-sm btn-error"
                }
                phx-click="resolve_permission"
                phx-value-request-id={@pending_permission.payload["request_id"]}
                phx-value-option-id={option["optionId"]}
              >
                {option["name"]}
              </button>
            </div>
          </section>

          <section class="rounded border border-base-300 bg-base-100 p-4">
            <h2 class="font-semibold">Control</h2>
            <.form for={to_form(%{})} phx-submit="send_prompt" class="mt-3 space-y-2">
              <textarea
                name="prompt"
                class="textarea textarea-bordered min-h-28 w-full"
                placeholder="Prompt this run. Try: permission"
                disabled={@run.status == "waiting"}
              >{@prompt}</textarea>
              <div class="flex gap-2">
                <button class="btn btn-primary flex-1" disabled={@run.status == "waiting"}>
                  Send
                </button>
                <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
              </div>
            </.form>
            <div class="mt-3 grid grid-cols-2 gap-2">
              <button
                class="btn btn-sm"
                phx-click="sample_prompt"
                phx-value-text="hello from LiveView"
                disabled={@run.status == "waiting"}
              >
                Echo
              </button>
              <button
                class="btn btn-sm btn-warning"
                phx-click="sample_prompt"
                phx-value-text="permission"
                disabled={@run.status == "waiting"}
              >
                Ask permission
              </button>
            </div>
          </section>

          <section class="rounded border border-base-300 bg-base-100 p-4 text-sm">
            <h2 class="font-semibold">Run facts</h2>
            <dl class="mt-3 space-y-2">
              <div>
                <dt class="text-base-content/50">Agent</dt>
                <dd>{@run.agent}</dd>
              </div>
              <div>
                <dt class="text-base-content/50">Agent session</dt>
                <dd class="break-all">{@run.agent_session_id || "starting"}</dd>
              </div>
            </dl>
          </section>
        </aside>
      </section>
    </main>
    """
  end
end
