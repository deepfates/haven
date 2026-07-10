defmodule Haven.TerminalSessions do
  @output_preview_limit 4_000

  import Ecto.Query

  alias Haven.Repo
  alias Haven.TerminalSessions.TerminalSession

  def create_session!(run_id, attrs) do
    attrs =
      attrs
      |> Map.put(:run_id, run_id)
      |> Map.put_new(:status, "running")

    %TerminalSession{}
    |> TerminalSession.changeset(attrs)
    |> Repo.insert!()
  end

  def list_for_run(run_id) do
    Repo.all(
      from s in TerminalSession,
        where: s.run_id == ^run_id,
        order_by: [asc: s.inserted_at]
    )
  end

  def record_output!(run_id, terminal_id, output, exit_status) do
    session = get_session!(run_id, terminal_id)

    attrs =
      output_attrs(output)
      |> Map.put(:exit_status, exit_status)
      |> maybe_put_status(session, exit_status, "exited")

    session
    |> TerminalSession.changeset(attrs)
    |> Repo.update!()
  end

  def mark_exited!(run_id, terminal_id, exit_status) do
    session = get_session!(run_id, terminal_id)

    status =
      if session.status == "killed" do
        "killed"
      else
        "exited"
      end

    session
    |> TerminalSession.changeset(%{status: status, exit_status: exit_status})
    |> Repo.update!()
  end

  def mark_killed!(run_id, terminal_id) do
    now = DateTime.utc_now(:second)

    run_id
    |> get_session!(terminal_id)
    |> TerminalSession.changeset(%{status: "killed", killed_at: now})
    |> Repo.update!()
  end

  def mark_released!(run_id, terminal_id) do
    now = DateTime.utc_now(:second)
    session = get_session!(run_id, terminal_id)

    status =
      if session.status == "running" do
        "released"
      else
        session.status
      end

    session
    |> TerminalSession.changeset(%{status: status, released_at: now})
    |> Repo.update!()
  end

  def mark_failed!(run_id, terminal_id) do
    run_id
    |> get_session!(terminal_id)
    |> TerminalSession.changeset(%{status: "failed"})
    |> Repo.update!()
  end

  defp get_session!(run_id, terminal_id) do
    Repo.get_by!(TerminalSession, run_id: run_id, terminal_id: terminal_id)
  end

  defp output_attrs(output) do
    %{
      output_bytes: byte_size(output),
      output_preview: String.slice(output, 0, @output_preview_limit),
      output_truncated: String.length(output) > @output_preview_limit
    }
  end

  defp maybe_put_status(attrs, _session, nil, _status), do: attrs
  defp maybe_put_status(attrs, %{status: "killed"}, _exit_status, _status), do: attrs

  defp maybe_put_status(attrs, _session, _exit_status, status),
    do: Map.put(attrs, :status, status)
end
