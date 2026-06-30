defmodule HavenWeb.DevControllerTest do
  use HavenWeb.ConnCase

  alias Haven.Events
  alias Haven.Runs
  alias HavenWeb.DevController

  @tag :tmp_dir
  test "dev sample controls exercise file and terminal capability paths", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "README.md"), "dev controller fixture\n")

    {:ok, run} = Runs.create_run(%{"title" => "Dev samples", "workspace" => tmp_dir})
    stop_run_server_on_exit(run.id)
    sync_run_server!(run.id)
    Events.subscribe(run.id)

    assert_sample_ok(run.id, "read-file")

    assert_receive {:event_appended,
                    %{
                      type: "file_read_requested",
                      payload: %{"path" => "README.md"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{"request_id" => read_request_id}
                    }},
                   1_000

    :ok = Runs.resolve_permission(run.id, read_request_id, "allow")
    assert_receive {:event_appended, %{type: "file_read_succeeded"}}, 1_000
    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000

    assert_sample_ok(run.id, "write-file")

    assert_receive {:event_appended,
                    %{
                      type: "file_write_requested",
                      payload: %{"path" => "haven-written.txt"}
                    }},
                   1_000

    assert_receive {:event_appended,
                    %{
                      type: "permission_requested",
                      payload: %{"request_id" => write_request_id}
                    }},
                   1_000

    :ok = Runs.resolve_permission(run.id, write_request_id, "allow")
    assert_receive {:event_appended, %{type: "file_write_succeeded"}}, 1_000
    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
    assert File.read!(Path.join(tmp_dir, "haven-written.txt")) == "written by Haven ACP\n"

    assert_sample_ok(run.id, "terminal")

    assert_receive {:event_appended, %{type: "terminal_create_requested"}}, 1_000
    assert_receive {:event_appended, %{type: "terminal_created"}}, 1_000
    assert_receive {:event_appended, %{type: "terminal_output_succeeded"}}, 1_000
    assert_receive {:event_appended, %{type: "turn_finished"}}, 1_000
  end

  defp assert_sample_ok(run_id, sample) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> DevController.sample(%{"id" => run_id, "sample" => sample})

    assert json_response(conn, 200) == %{"ok" => true}
  end

  defp sync_run_server!(run_id) do
    [{pid, _}] = Registry.lookup(Haven.Runs.Registry, run_id)
    _state = :sys.get_state(pid)
    :ok
  end

  defp stop_run_server_on_exit(run_id) do
    on_exit(fn ->
      if Runs.started?(run_id), do: Runs.stop_run(run_id)
    end)
  end
end
