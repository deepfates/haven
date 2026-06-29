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
end
