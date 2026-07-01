defmodule Haven.PortIOTest do
  use ExUnit.Case, async: true

  alias Haven.PortIO

  test "acts as an IO device over a stdio port" do
    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("cat"),
        args: []
      )

    assert :ok = IO.write(io, "hello\n")
    assert "hello\n" = IO.read(io, :line)
  end

  test "notifies an observer about raw incoming port lines" do
    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("cat"),
        args: [],
        observer: self()
      )

    assert :ok = IO.write(io, "observed\n")
    assert "observed\n" = IO.read(io, :line)
    assert_receive {:port_io_line, ^io, "observed\n"}
  end

  test "preserves a final unterminated line when the process exits" do
    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("sh"),
        args: ["-c", "printf partial-frame"]
      )

    assert "partial-frame" = IO.read(io, :line)
    assert :eof = IO.read(io, :line)
    assert PortIO.exit_status(io) == 0
  end

  test "reports a device error when writing after process exit" do
    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("sh"),
        args: ["-c", "true"]
      )

    assert :eof = IO.read(io, :line)

    assert_raise ArgumentError, ~r/bad file number/, fn ->
      IO.write(io, "late write\n")
    end

    assert PortIO.exit_status(io) == 0
  end

  test "notifies observers about a final unterminated line" do
    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("sh"),
        args: ["-c", "printf partial-observed"],
        observer: self()
      )

    assert "partial-observed" = IO.read(io, :line)
    assert_receive {:port_io_line, ^io, "partial-observed"}
  end

  test "passes environment variables to the spawned process" do
    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("sh"),
        args: ["-c", ~s|printf "%s\\n" "$HAVEN_PORT_IO_SMOKE"|],
        env: [{"HAVEN_PORT_IO_SMOKE", "visible"}]
      )

    assert "visible\n" = IO.read(io, :line)
  end

  test "starts the spawned process in the configured working directory" do
    tmp_dir =
      Path.join("/private/tmp", "haven-port-io-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, io} =
      PortIO.start_link(
        executable: System.find_executable("pwd"),
        cd: tmp_dir
      )

    assert Path.expand(String.trim(IO.read(io, :line))) == Path.expand(tmp_dir)
  end
end
