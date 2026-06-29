defmodule Haven.AgentProbe do
  @moduledoc """
  Runs an end-to-end Haven run against a configured ACP agent.

  The probe intentionally goes through `Haven.Runs` instead of talking directly
  to an agent process, so it exercises the same app path as the browser UI:
  run creation, agent boot, ACP initialization, prompting, permission
  resolution, status projection, and durable event storage.
  """

  alias Haven.Events
  alias Haven.Runs

  @terminal_statuses ~w(closed failed)
  @default_timeout 30_000

  @type permission_resolution :: nil | String.t()

  @type report :: %{
          run_id: String.t(),
          agent: String.t(),
          workspace: String.t(),
          status: String.t(),
          events: [map()],
          prompt: String.t()
        }

  @spec run(keyword()) :: {:ok, report()} | {:error, atom(), report()}
  def run(opts) do
    agent = Keyword.get(opts, :agent, "stub-acp")
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    prompt = Keyword.get(opts, :prompt, "hello from Haven agent probe")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    permission_resolution = Keyword.get(opts, :resolve_permissions)

    with {:ok, run} <-
           Runs.create_run(%{
             "title" => Keyword.get(opts, :title, title(agent)),
             "workspace" => workspace,
             "agent" => agent
           }),
         {:ok, _run} <- wait_for_boot(run.id, timeout),
         :ok <- Runs.send_prompt(run.id, prompt),
         {:ok, finished} <- wait_for_finish(run.id, timeout, permission_resolution) do
      {:ok, report(finished, prompt)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, :invalid_run, invalid_run_report(agent, workspace, prompt, changeset)}

      {:error, reason, run_id} ->
        {:error, reason, report(Runs.get_run!(run_id), prompt)}

      {:error, reason} ->
        {:error, reason, invalid_run_report(agent, workspace, prompt, nil)}
    end
  end

  defp title(agent), do: "Agent probe: #{agent}"

  defp wait_for_boot(run_id, timeout) do
    wait_until(run_id, timeout, fn run ->
      cond do
        run.status == "idle" and run.agent_session_id -> {:halt, {:ok, run}}
        run.status in @terminal_statuses -> {:halt, {:error, :boot_failed, run.id}}
        true -> :cont
      end
    end)
  end

  defp wait_for_finish(run_id, timeout, permission_resolution) do
    wait_until(run_id, timeout, fn run ->
      cond do
        run.status == "waiting" and is_binary(permission_resolution) ->
          resolve_pending_permissions(run.id, permission_resolution)
          :cont

        run.status == "waiting" ->
          {:halt, {:error, :permission_required, run.id}}

        run.status == "failed" ->
          {:halt, {:error, :run_failed, run.id}}

        run.status == "closed" ->
          {:halt, {:ok, run}}

        run.status == "idle" ->
          {:halt, {:ok, run}}

        true ->
          :cont
      end
    end)
  end

  defp wait_until(run_id, timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(run_id, deadline, fun)
  end

  defp do_wait_until(run_id, deadline, fun) do
    run = Runs.get_run!(run_id)

    case fun.(run) do
      {:halt, result} ->
        result

      :cont ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout, run_id}
        else
          receive do
          after
            50 -> do_wait_until(run_id, deadline, fun)
          end
        end
    end
  end

  defp resolve_pending_permissions(run_id, option_id) do
    run_id
    |> pending_permission_ids()
    |> Enum.each(fn request_id ->
      _ = Runs.resolve_permission(run_id, request_id, option_id)
    end)
  end

  defp pending_permission_ids(run_id) do
    events = Events.list_for_run(run_id)

    resolved =
      events
      |> Enum.filter(&(&1.type in ["permission_resolved", "permission_resolution_ignored"]))
      |> Enum.map(& &1.payload["request_id"])
      |> MapSet.new()

    events
    |> Enum.filter(&(&1.type == "permission_requested"))
    |> Enum.map(& &1.payload["request_id"])
    |> Enum.reject(&MapSet.member?(resolved, &1))
  end

  defp report(run, prompt) do
    %{
      run_id: run.id,
      agent: run.agent,
      workspace: run.workspace,
      status: run.status,
      prompt: prompt,
      events: Enum.map(Events.list_for_run(run.id), &event_report/1)
    }
  end

  defp invalid_run_report(agent, workspace, prompt, changeset) do
    %{
      run_id: nil,
      agent: agent,
      workspace: workspace,
      status: "invalid",
      prompt: prompt,
      errors: changeset_errors(changeset),
      events: []
    }
  end

  defp event_report(event) do
    %{
      seq: event.seq,
      type: event.type,
      payload: event.payload
    }
  end

  defp changeset_errors(nil), do: %{}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
