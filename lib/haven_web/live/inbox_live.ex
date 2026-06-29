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

  defp status_class("waiting"), do: "badge badge-warning"
  defp status_class("running"), do: "badge badge-info"
  defp status_class("initializing"), do: "badge badge-neutral"
  defp status_class("failed"), do: "badge badge-error"
  defp status_class(_), do: "badge badge-ghost"

  defp run_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/runs/#{@run.id}"}
      class="block rounded border border-base-300 bg-base-100 p-4 hover:bg-base-200"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="truncate font-semibold">{@run.title}</h3>
          <p class="mt-1 truncate text-sm text-base-content/60">{@run.workspace}</p>
        </div>
        <span class={status_class(@run.status)}>{@run.status}</span>
      </div>
      <div class="mt-3 text-xs text-base-content/50">
        {@run.agent} · updated {Calendar.strftime(@run.updated_at, "%H:%M:%S")}
      </div>
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-base-200">
      <section class="mx-auto flex max-w-5xl flex-col gap-6 p-4 md:p-8">
        <header class="flex flex-col gap-4 border-b border-base-300 pb-5 md:flex-row md:items-end md:justify-between">
          <div>
            <p class="text-sm font-medium text-base-content/60">Haven</p>
            <h1 class="text-3xl font-bold tracking-normal">Agent attention inbox</h1>
          </div>

          <.form for={@form} phx-submit="create_run" class="flex gap-2">
            <input
              name="title"
              class="input input-bordered w-64"
              placeholder="Run goal"
              autocomplete="off"
            />
            <button class="btn btn-primary">Start</button>
          </.form>
        </header>

        <section :if={@needs_you != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase text-base-content/60">Needs You</h2>
          <div class="grid gap-3">
            <.run_card :for={run <- @needs_you} run={run} />
          </div>
        </section>

        <section :if={@running != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase text-base-content/60">Running</h2>
          <div class="grid gap-3 md:grid-cols-2">
            <.run_card :for={run <- @running} run={run} />
          </div>
        </section>

        <section class="space-y-3">
          <h2 class="text-sm font-semibold uppercase text-base-content/60">History</h2>
          <div
            :if={@history == []}
            class="rounded border border-dashed border-base-300 bg-base-100 p-8 text-center text-base-content/60"
          >
            No quiet runs yet. Start one above.
          </div>
          <div class="grid gap-3 md:grid-cols-2">
            <.run_card :for={run <- @history} run={run} />
          </div>
        </section>
      </section>
    </main>
    """
  end
end
