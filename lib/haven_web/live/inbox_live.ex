defmodule HavenWeb.InboxLive do
  use HavenWeb, :live_view

  alias Haven.Agents
  alias Haven.Runs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Haven")
     |> assign(:form, to_form(default_run_params()))
     |> assign(:agent_options, Agents.available())
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
      "agent" => "stub-acp"
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

    agent =
      params
      |> Map.get("agent", defaults["agent"])
      |> String.trim()

    %{
      "title" => if(title == "", do: "Untitled run", else: title),
      "workspace" => if(workspace == "", do: defaults["workspace"], else: Path.expand(workspace)),
      "agent" => if(agent == "", do: defaults["agent"], else: agent)
    }
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
              <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto] md:items-end">
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
              <.run_card :for={run <- @history} run={run} show_archive={true} />
            </div>
          </section>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
