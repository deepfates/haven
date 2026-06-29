defmodule Haven.ACPWire do
  @moduledoc """
  Boundary around `agent_client_protocol` for newline-delimited JSON-RPC.

  Haven owns supervision, persistence, and LiveView projections, while protocol
  messages at the stdio edge use ACP's RPC/schema encoders.
  """

  def encode(message) do
    message
    |> to_rpc_map()
    |> ACP.RPC.JsonRpcMessage.wrap()
    |> ACP.RPC.JsonRpcMessage.encode!()
  end

  def send(port, message) when is_port(port) do
    Port.command(port, encode(message) <> "\n")
  end

  def send(message), do: IO.puts(encode(message))

  def decode!(line) do
    {:ok, message} = ACP.RPC.JsonRpcMessage.decode(line)
    message
  end

  defp to_rpc_map(%ACP.RPC.Request{} = message), do: ACP.RPC.Request.to_json(message)
  defp to_rpc_map(%ACP.RPC.Notification{} = message), do: ACP.RPC.Notification.to_json(message)
  defp to_rpc_map({:result, _id, _result} = message), do: ACP.RPC.Response.to_json(message)
  defp to_rpc_map({:error, _id, _error} = message), do: ACP.RPC.Response.to_json(message)
  defp to_rpc_map(message) when is_map(message), do: message
end
