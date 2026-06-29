defmodule Haven.Runs.ACPClientHandler do
  @moduledoc false

  alias Haven.Runs.RunServer

  def handle_request({:request_permission, request}, run_server) do
    RunServer.agent_permission_requested(run_server, request)
  end

  def handle_request(_request, _run_server), do: {:error, ACP.Error.method_not_found()}

  def handle_notification(_notification, _run_server), do: :ok
end
