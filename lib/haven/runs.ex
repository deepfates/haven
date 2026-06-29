defmodule Haven.Runs do
  import Ecto.Query

  alias Haven.Events
  alias Haven.Repo
  alias Haven.Runs.{Run, RunServer}

  def list_runs do
    Repo.all(from r in Run, order_by: [desc: r.updated_at])
  end

  def get_run!(id), do: Repo.get!(Run, id)

  def create_run(attrs) do
    attrs =
      attrs
      |> Map.put_new("workspace", File.cwd!())
      |> Map.put_new("agent", "stub-acp")
      |> Map.put_new("status", "idle")

    result =
      Repo.transaction(fn ->
        case %Run{} |> Run.changeset(attrs) |> Repo.insert() do
          {:ok, run} ->
            Events.append!(run.id, "run_created", %{
              "title" => run.title,
              "workspace" => run.workspace,
              "agent" => run.agent
            })

            run

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, run} <- result do
      _ = start_run(run.id)
      {:ok, run}
    end
  end

  def start_run(run_id) do
    spec = {RunServer, run_id: run_id}

    case DynamicSupervisor.start_child(Haven.Runs.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def started?(run_id) do
    match?([{_pid, _}], Registry.lookup(Haven.Runs.Registry, run_id))
  end

  def ensure_started(run_id) do
    case Registry.lookup(Haven.Runs.Registry, run_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case get_run!(run_id) do
          %{status: status} when status in ["closed", "failed"] -> {:error, :terminal_run}
          _run -> start_run(run_id)
        end
    end
  end

  def reconnect_run(run_id) do
    run = get_run!(run_id)

    cond do
      run.status == "closed" ->
        {:error, :closed_run}

      started?(run_id) and run.status != "failed" ->
        {:error, :live_run}

      true ->
        if started?(run_id), do: stop_run(run_id)

        Events.append!(run_id, "run_reconnect_requested", %{
          "previous_status" => run.status
        })

        update_status!(run_id, %{status: "idle", agent_session_id: nil})
        start_run(run_id)
    end
  end

  def stop_run(run_id) do
    case Registry.lookup(Haven.Runs.Registry, run_id) do
      [{pid, _}] -> GenServer.call(pid, :shutdown, :infinity)
      [] -> :ok
    end
  end

  def send_prompt(run_id, text) do
    with {:ok, pid} <- ensure_started(run_id) do
      GenServer.call(pid, {:send_prompt, text}, 30_000)
    end
  end

  def resolve_permission(run_id, request_id, option_id) do
    with {:ok, pid} <- ensure_started(run_id) do
      GenServer.call(pid, {:resolve_permission, request_id, option_id}, 30_000)
    end
  end

  def cancel(run_id) do
    with {:ok, pid} <- ensure_started(run_id) do
      GenServer.call(pid, :cancel, 30_000)
    end
  end

  def update_status!(run_id, attrs) do
    run = get_run!(run_id)

    run
    |> Run.changeset(attrs)
    |> Repo.update!()
    |> tap(fn updated ->
      Phoenix.PubSub.broadcast(Haven.PubSub, "runs", {:run_updated, updated})
    end)
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Haven.PubSub, "runs")
end
