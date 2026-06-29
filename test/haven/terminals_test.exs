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
end
