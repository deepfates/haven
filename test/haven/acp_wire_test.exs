defmodule Haven.ACPWireTest do
  use ExUnit.Case, async: true

  alias Haven.ACPWire

  test "round-trips ACP request structs through JSON-RPC" do
    request =
      ACP.RPC.Request.new(
        "init",
        "initialize",
        ACP.InitializeRequest.new(ACP.ProtocolVersion.v1()) |> ACP.InitializeRequest.to_json()
      )

    assert %ACP.RPC.Request{id: "init", method: "initialize"} =
             request
             |> ACPWire.encode()
             |> ACPWire.decode!()
  end

  test "round-trips ACP responses through JSON-RPC" do
    response =
      ACP.ProtocolVersion.v1()
      |> ACP.InitializeResponse.new()
      |> ACP.InitializeResponse.to_json()

    assert {:result, "init", result} =
             "init"
             |> ACP.RPC.Response.result(response)
             |> ACPWire.encode()
             |> ACPWire.decode!()

    assert {:ok, %ACP.InitializeResponse{}} = ACP.InitializeResponse.from_json(result)
  end

  test "round-trips ACP notification structs through JSON-RPC" do
    notification =
      ACP.RPC.Notification.new(
        "session/update",
        ACP.SessionNotification.new(
          "session-1",
          {:agent_message_chunk, ACP.ContentChunk.new(ACP.ContentBlock.from_string("hello"))}
        )
        |> ACP.SessionNotification.to_json()
      )

    assert %ACP.RPC.Notification{method: "session/update"} =
             notification
             |> ACPWire.encode()
             |> ACPWire.decode!()
  end
end
