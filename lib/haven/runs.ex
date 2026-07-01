defmodule Haven.Runs do
  import Ecto.Query

  alias Haven.Events
  alias Haven.Agents
  alias Haven.PermissionAudits
  alias Haven.Repo
  alias Haven.Runs.{Run, RunServer}

  def list_runs do
    Repo.all(from r in Run, where: is_nil(r.archived_at), order_by: [desc: r.updated_at])
  end

  def list_archived_runs do
    Repo.all(from r in Run, where: not is_nil(r.archived_at), order_by: [desc: r.archived_at])
  end

  def unread_summary(opts \\ []) do
    exclude_run_id = Keyword.get(opts, :exclude_run_id)

    query =
      from r in Run,
        where: is_nil(r.archived_at) and r.purpose != "diagnostic"

    query =
      if is_binary(exclude_run_id) do
        from r in query, where: r.id != ^exclude_run_id
      else
        query
      end

    runs = Repo.all(query)

    latest_events =
      runs
      |> Enum.map(& &1.id)
      |> Events.latest_by_run_id()

    Enum.reduce(runs, %{runs: 0, events: 0}, fn run, summary ->
      unread_events =
        case Map.get(latest_events, run.id) do
          %{seq: latest_seq} when is_integer(latest_seq) ->
            max(latest_seq - run.last_viewed_event_seq, 0)

          _latest_event ->
            0
        end

      if unread_events > 0 do
        %{summary | runs: summary.runs + 1, events: summary.events + unread_events}
      else
        summary
      end
    end)
  end

  def prune_archived_before(%DateTime{} = cutoff) do
    {count, _deleted} =
      Repo.delete_all(
        from r in Run,
          where: not is_nil(r.archived_at) and r.archived_at < ^cutoff
      )

    count
  end

  def get_run!(id), do: Repo.get!(Run, id)

  def create_run(attrs) do
    attrs =
      attrs
      |> Map.put_new("workspace", File.cwd!())
      |> Map.put_new("agent", "stub-acp")
      |> Map.put_new("status", "idle")
      |> Map.put_new("purpose", "work")

    changeset = %Run{} |> Run.changeset(attrs) |> validate_agent_launch()

    result =
      if changeset.valid? do
        Repo.transaction(fn ->
          case Repo.insert(changeset) do
            {:ok, run} ->
              append_run_created!(run)
              run

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
      else
        {:error, %{changeset | action: :insert}}
      end

    with {:ok, run} <- result do
      _ = start_run(run.id)
      {:ok, run}
    end
  end

  defp append_run_created!(run) do
    Events.append!(run.id, "run_created", %{
      "title" => run.title,
      "workspace" => run.workspace,
      "agent" => run.agent,
      "purpose" => run.purpose,
      "capability_policy" => Run.capability_policy(run.capability_policy)
    })
  end

  defp validate_agent_launch(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_agent_launch(changeset) do
    agent = Ecto.Changeset.get_field(changeset, :agent)
    workspace = Ecto.Changeset.get_field(changeset, :workspace)

    case Agents.command(agent, workspace) do
      {:ok, _command} ->
        changeset

      {:error, reason} ->
        Ecto.Changeset.add_error(changeset, :agent, agent_launch_error(reason))
    end
  end

  defp agent_launch_error({:unknown_agent, agent}), do: "is not configured: #{agent}"

  defp agent_launch_error({:missing_executable, executable}),
    do: "executable is missing: #{executable}"

  defp agent_launch_error({:missing_cwd, cwd}), do: "working directory is missing: #{cwd}"
  defp agent_launch_error({:invalid_agent_field, field}), do: "configuration has invalid #{field}"
  defp agent_launch_error(_reason), do: "cannot be launched"

  def start_run(run_id, opts \\ []) do
    run = get_run!(run_id)

    cond do
      archived?(run) ->
        {:error, :archived_run}

      run.status in ["closed", "failed"] ->
        {:error, :terminal_run}

      missing_workspace?(run) ->
        {:error, {:missing_workspace, run.workspace}}

      true ->
        start_unarchived_run(run_id, opts)
    end
  end

  def started?(%Run{} = run) do
    case run do
      %{archived_at: archived_at} when not is_nil(archived_at) -> false
      %{status: status} when status in ["closed", "failed"] -> false
      %{id: run_id} -> registry_started?(run_id)
    end
  end

  def started?(run_id), do: run_id |> get_run!() |> started?()

  def ensure_started(run_id) do
    case get_run!(run_id) do
      %{archived_at: archived_at} when not is_nil(archived_at) ->
        {:error, :archived_run}

      %{status: status} when status in ["closed", "failed"] ->
        {:error, :terminal_run}

      run ->
        case Registry.lookup(Haven.Runs.Registry, run_id) do
          [{pid, _}] ->
            {:ok, pid}

          [] ->
            if missing_workspace?(run) do
              {:error, {:missing_workspace, run.workspace}}
            else
              start_unarchived_run(run_id, [])
            end
        end
    end
  end

  def reconnect_run(run_id, opts \\ []) do
    run = get_run!(run_id)

    cond do
      archived?(run) ->
        {:error, :archived_run}

      run.status == "closed" ->
        {:error, :closed_run}

      registry_started?(run_id) and run.status != "failed" ->
        {:error, :live_run}

      missing_workspace?(run) ->
        {:error, {:missing_workspace, run.workspace}}

      true ->
        if registry_started?(run_id), do: stop_run(run_id)

        Events.append!(run_id, "run_reconnect_requested", %{
          "previous_status" => run.status
        })

        fail_unresolved_turn!(run_id, "run_reconnect_requested")
        cancel_unresolved_permissions!(run_id, "run_reconnect_requested")
        update_status!(run_id, %{status: "idle", agent_session_id: nil})
        start_run(run_id, opts)
    end
  end

  def retry_last_prompt(run_id) do
    run = get_run!(run_id)

    cond do
      archived?(run) ->
        {:error, :archived_run}

      run.status != "failed" ->
        {:error, :not_failed}

      true ->
        case last_user_prompt(run_id) do
          nil -> {:error, :no_prompt}
          prompt -> reconnect_run(run_id, retry_prompt: prompt)
        end
    end
  end

  def continue_failed_run(run_id, prompt) when is_binary(prompt) do
    run = get_run!(run_id)
    prompt = String.trim(prompt)

    cond do
      archived?(run) ->
        {:error, :archived_run}

      run.status != "failed" ->
        {:error, :not_failed}

      prompt == "" ->
        {:error, :blank_prompt}

      true ->
        reconnect_run(run_id, continue_prompt: prompt)
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

  def archive_run(run_id) do
    run = get_run!(run_id)

    cond do
      run.status not in ["closed", "failed"] ->
        {:error, :not_archivable}

      run.archived_at ->
        {:ok, run}

      true ->
        archived_at = DateTime.utc_now(:second)

        Repo.transaction(fn ->
          updated =
            run
            |> Ecto.Changeset.change(archived_at: archived_at)
            |> Repo.update!()

          Events.append!(run_id, "run_archived", %{
            "actor" => "local_user",
            "archived_at" => DateTime.to_iso8601(archived_at),
            "previous_status" => run.status
          })

          updated
        end)
        |> case do
          {:ok, updated} ->
            if registry_started?(run_id), do: stop_run(run_id)
            Phoenix.PubSub.broadcast(Haven.PubSub, "runs", {:run_updated, updated})
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def mark_viewed(run_or_id, latest_event_seq, opts \\ [])

  def mark_viewed(%Run{} = run, latest_event_seq, opts)
      when is_integer(latest_event_seq) and latest_event_seq >= 0 do
    {count, _updates} =
      Repo.update_all(
        from(r in Run,
          where: r.id == ^run.id and r.last_viewed_event_seq < ^latest_event_seq
        ),
        set: [last_viewed_event_seq: latest_event_seq]
      )

    updated =
      if count > 0 do
        %{run | last_viewed_event_seq: latest_event_seq}
      else
        run
      end

    if count > 0 and Keyword.get(opts, :broadcast?, true) do
      Phoenix.PubSub.broadcast(Haven.PubSub, "runs", {:run_updated, updated})
    end

    {:ok, updated}
  end

  def mark_viewed(%Run{} = run, _latest_event_seq, _opts), do: {:ok, run}

  def mark_viewed(run_id, latest_event_seq, opts) when is_binary(run_id) do
    run = get_run!(run_id)
    mark_viewed(run, latest_event_seq, opts)
  end

  def mark_viewed(run_id, _latest_event_seq, _opts) do
    if is_binary(run_id) do
      {:ok, get_run!(run_id)}
    else
      {:error, :invalid_run}
    end
  end

  def mark_latest_viewed(run_id, opts \\ []) when is_binary(run_id) do
    latest_event_seq =
      case Events.latest_by_run_id([run_id]) do
        %{^run_id => %{seq: seq}} -> seq
        _latest_events -> 0
      end

    mark_viewed(run_id, latest_event_seq, opts)
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

  defp start_unarchived_run(run_id, opts) do
    spec = {RunServer, Keyword.put(opts, :run_id, run_id)}

    case DynamicSupervisor.start_child(Haven.Runs.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp archived?(%Run{archived_at: archived_at}), do: not is_nil(archived_at)

  defp missing_workspace?(%Run{workspace: workspace}) when is_binary(workspace) do
    not File.dir?(workspace)
  end

  defp missing_workspace?(_run), do: true

  defp registry_started?(run_id) do
    match?([{_pid, _}], Registry.lookup(Haven.Runs.Registry, run_id))
  end

  defp last_user_prompt(run_id) do
    run_id
    |> Events.list_for_run()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: "user_message", payload: %{"text" => text}} when is_binary(text) -> text
      _event -> nil
    end)
  end

  defp fail_unresolved_turn!(run_id, reason) do
    events = Events.list_for_run(run_id)
    last_started_seq = last_event_seq(events, ["turn_started"])
    last_terminal_seq = last_event_seq(events, ["turn_finished", "turn_failed", "turn_cancelled"])

    if last_started_seq && last_started_seq > last_terminal_seq do
      Events.append!(run_id, "turn_failed", %{
        "error" => reason,
        "actor" => "system"
      })
    end
  end

  defp last_event_seq(events, types) do
    events
    |> Enum.filter(&(&1.type in types))
    |> Enum.map(& &1.seq)
    |> Enum.max(fn -> 0 end)
  end

  defp cancel_unresolved_permissions!(run_id, reason) do
    events = Events.list_for_run(run_id)

    resolved =
      events
      |> Enum.filter(&(&1.type == "permission_resolved"))
      |> MapSet.new(&to_string(&1.payload["request_id"]))

    events
    |> Enum.filter(&(&1.type == "permission_requested"))
    |> Enum.map(& &1.payload["request_id"])
    |> Enum.reject(&MapSet.member?(resolved, to_string(&1)))
    |> Enum.each(fn request_id ->
      payload = %{
        "request_id" => request_id,
        "option_id" => "cancelled",
        "outcome" => "cancelled",
        "reason" => reason,
        "actor" => "system"
      }

      Events.append!(run_id, "permission_resolved", payload)
      PermissionAudits.mark_resolved!(run_id, request_id, payload)
    end)
  end
end
