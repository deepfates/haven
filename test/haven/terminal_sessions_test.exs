defmodule Haven.TerminalSessionsTest do
  use Haven.DataCase, async: true

  alias Haven.Events
  alias Haven.Repo
  alias Haven.Runs.Run
  alias Haven.TerminalSessions

  test "records terminal lifecycle facts without storing unbounded output" do
    run = insert_run!()

    session =
      TerminalSessions.create_session!(run.id, %{
        terminal_id: "term-1",
        command: "printf",
        args: %{"items" => ["hello"]},
        cwd: run.workspace,
        executable: "/usr/bin/printf",
        env_keys: %{"items" => ["TOKEN"]},
        os_pid: 1234
      })

    assert session.status == "running"
    assert session.args == %{"items" => ["hello"]}
    assert session.env_keys == %{"items" => ["TOKEN"]}

    output = String.duplicate("a", 4_100)
    updated = TerminalSessions.record_output!(run.id, "term-1", output, 0)

    assert updated.status == "exited"
    assert updated.exit_status == 0
    assert updated.output_bytes == 4_100
    assert String.length(updated.output_preview) == 4_000
    assert updated.output_truncated

    released = TerminalSessions.mark_released!(run.id, "term-1")
    assert released.status == "exited"
    assert released.released_at

    assert [^released] = TerminalSessions.list_for_run(run.id)
  end

  test "preserves killed as the command outcome after wait and release cleanup" do
    run = insert_run!()

    TerminalSessions.create_session!(run.id, %{
      terminal_id: "term-2",
      command: "sleep",
      args: %{"items" => ["30"]},
      cwd: run.workspace
    })

    killed = TerminalSessions.mark_killed!(run.id, "term-2")
    assert killed.status == "killed"
    assert killed.killed_at

    exited = TerminalSessions.mark_exited!(run.id, "term-2", -1)
    assert exited.status == "killed"
    assert exited.exit_status == -1

    released = TerminalSessions.mark_released!(run.id, "term-2")
    assert released.status == "killed"
    assert released.released_at
  end

  defp insert_run! do
    run =
      %Run{}
      |> Run.changeset(%{
        title: "Terminal session run",
        workspace: File.cwd!(),
        agent: "stub-acp",
        status: "idle"
      })
      |> Repo.insert!()

    Events.append!(run.id, "run_created", %{
      "title" => run.title,
      "workspace" => run.workspace,
      "agent" => run.agent
    })

    run
  end
end
