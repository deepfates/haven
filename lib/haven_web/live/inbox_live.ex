defmodule HavenWeb.InboxLive do
  use HavenWeb, :live_view

  alias Haven.Runs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Haven")
     |> assign(:form, to_form(%{"title" => ""}))
     |> assign_runs()}
  end

  @impl true
  def handle_event("create_run", %{"title" => title}, socket) do
    title = if String.trim(title) == "", do: "Untitled run", else: String.trim(title)
    {:ok, run} = Runs.create_run(%{"title" => title})
    {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}
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

  defp status_class("waiting"), do: badge_class("border-amber-200 bg-amber-50 text-amber-700")
  defp status_class("running"), do: badge_class("border-sky-200 bg-sky-50 text-sky-700")
  defp status_class("initializing"), do: badge_class("border-zinc-200 bg-zinc-50 text-zinc-700")
  defp status_class("failed"), do: badge_class("border-rose-200 bg-rose-50 text-rose-700")
  defp status_class(_), do: badge_class("border-zinc-200 bg-white text-zinc-600")

  defp badge_class(tone) do
    "inline-flex shrink-0 items-center rounded-full border px-2.5 py-1 text-xs font-medium " <>
      tone
  end

  defp run_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/runs/#{@run.id}"}
      class="block rounded-lg border border-zinc-200 bg-white p-4 shadow-sm transition hover:border-zinc-300 hover:bg-zinc-50"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="truncate font-semibold text-zinc-950">{@run.title}</h3>
          <p class="mt-1 truncate text-sm text-zinc-500">{@run.workspace}</p>
        </div>
        <span class={status_class(@run.status)}>{@run.status}</span>
      </div>
      <div class="mt-3 text-xs text-zinc-500">
        {@run.agent} · updated {Calendar.strftime(@run.updated_at, "%H:%M:%S")}
      </div>
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="haven-inbox" class="min-h-dvh bg-zinc-100 text-zinc-950">
        <section class="mx-auto flex max-w-5xl flex-col gap-6 p-4 md:p-8">
          <header class="flex flex-col gap-4 border-b border-zinc-200 pb-5 md:flex-row md:items-end md:justify-between">
            <div>
              <p class="text-sm font-medium text-zinc-500">Haven</p>
              <h1 class="text-3xl font-bold tracking-normal">Agent attention inbox</h1>
            </div>

            <.form id="new-run-form" for={@form} phx-submit="create_run" class="flex gap-2">
              <.input
                field={@form[:title]}
                type="text"
                class="h-10 w-64 rounded-md border border-zinc-300 bg-white px-3 text-sm shadow-sm outline-none transition placeholder:text-zinc-400 focus:border-zinc-900 focus:ring-2 focus:ring-zinc-900/10"
                placeholder="Run goal"
                autocomplete="off"
              />
              <button
                id="start-run-button"
                class="h-10 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Start
              </button>
            </.form>
          </header>

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
              <.run_card :for={run <- @history} run={run} />
            </div>
          </section>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
