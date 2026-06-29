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
end
