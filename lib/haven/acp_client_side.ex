defmodule Haven.ACPClientSide do
  @moduledoc """
  Haven's client-side ACP decoder.

  The upstream Elixir ACP package intentionally maps known protocol payloads to
  typed structs, but real agents may emit newer session update variants before
  the package knows about them. Haven treats those as raw extension-style
  session updates so one unknown notification cannot bring down the run.
  """

  @behaviour ACP.Side

  @impl true
  def decode_request(method, params), do: ACP.ClientSide.decode_request(method, params)

  @impl true
  def decode_notification("session/update", params) when is_map(params) do
    case typed_session_update(params) do
      {:ok, notification} ->
        {:ok, {:session_notification, notification}}

      {:error, _reason} ->
        {:ok, {:ext_notification, %ACP.ExtNotification{method: "session/update", params: params}}}
    end
  end

  def decode_notification(method, params), do: ACP.ClientSide.decode_notification(method, params)

  defp typed_session_update(params) do
    try do
      ACP.SessionNotification.from_json(params)
    rescue
      FunctionClauseError -> {:error, :unknown_session_update}
      MatchError -> {:error, :invalid_session_update}
    end
  end
end
