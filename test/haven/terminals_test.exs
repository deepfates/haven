defmodule Haven.TerminalsTest do
  use ExUnit.Case, async: true

  alias Haven.Terminals

  @tag :tmp_dir
  test "runs a command inside the workspace and captures output", %{tmp_dir: tmp_dir} do
    request =
      "stub-session"
      |> ACP.CreateTerminalRequest.new("echo")
      |> Map.put(:args, ["hello"])

    assert {:ok, opts} = Terminals.command_options(tmp_dir, request)

    pid = start_supervised!({Terminals, opts})

    assert {:ok, 0} = Terminals.wait_for_exit(pid)
    assert {:ok, output, 0} = Terminals.output(pid)
    assert String.trim(output) == "hello"
  end

  @tag :tmp_dir
  test "rejects terminal working directories outside the workspace", %{tmp_dir: tmp_dir} do
    request =
      "stub-session"
      |> ACP.CreateTerminalRequest.new("echo")
      |> Map.put(:cwd, "../outside")

    assert {:error, {:outside_workspace, outside}} =
             Terminals.command_options(tmp_dir, request)

    assert outside == Path.expand("../outside", tmp_dir)
  end

  @tag :tmp_dir
  test "settles waiters when a command is killed", %{tmp_dir: tmp_dir} do
    request =
      "stub-session"
      |> ACP.CreateTerminalRequest.new("sleep")
      |> Map.put(:args, ["30"])

    assert {:ok, opts} = Terminals.command_options(tmp_dir, request)

    pid = start_supervised!({Terminals, opts})

    assert :ok = Terminals.kill(pid)
    assert {:ok, -1} = Terminals.wait_for_exit(pid)
  end

  @tag :tmp_dir
  test "kills shell-launched child processes", %{tmp_dir: tmp_dir} do
    child_pid_path = Path.join(tmp_dir, "child.pid")

    request =
      "stub-session"
      |> ACP.CreateTerminalRequest.new("sh")
      |> Map.put(:args, [
        "-c",
        "sleep 30 & echo $! > #{child_pid_path}; wait"
      ])

    assert {:ok, opts} = Terminals.command_options(tmp_dir, request)

    pid = start_supervised!({Terminals, opts})
    child_pid = wait_for_child_pid!(child_pid_path)

    assert os_pid_alive?(child_pid)
    assert :ok = Terminals.kill(pid)
    assert {:ok, -1} = Terminals.wait_for_exit(pid)
    refute wait_until_os_pid_alive?(child_pid)
  end

  defp wait_for_child_pid!(path) do
    wait_until(fn ->
      with true <- File.exists?(path),
           {pid, ""} <- path |> File.read!() |> String.trim() |> Integer.parse() do
        {:ok, pid}
      else
        _ -> :cont
      end
    end)
  end

  defp wait_until_os_pid_alive?(pid) do
    wait_until(fn ->
      if os_pid_alive?(pid), do: :cont, else: {:ok, false}
    end)
  catch
    :timeout -> true
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: throw(:timeout)

  defp wait_until(fun, attempts) do
    case fun.() do
      {:ok, value} ->
        value

      :cont ->
        receive do
        after
          10 -> wait_until(fun, attempts - 1)
        end
    end
  end

  defp os_pid_alive?(pid) do
    case System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _other -> false
    end
  end
end
