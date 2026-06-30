defmodule HavenWeb.DevController do
  use HavenWeb, :controller

  alias Haven.Runs

  def create_run(conn, params) do
    attrs =
      params
      |> Map.take(["title", "workspace", "agent"])
      |> Map.put_new("title", "Dev run")
      |> Map.put_new("workspace", File.cwd!())
      |> Map.put_new("agent", "stub-acp")

    case Runs.create_run(attrs) do
      {:ok, run} ->
        json(conn, %{
          ok: true,
          run: %{
            id: run.id,
            title: run.title,
            workspace: run.workspace,
            agent: run.agent,
            status: run.status
          }
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, errors: changeset_errors(changeset)})
    end
  end

  def sample(conn, %{"id" => id, "sample" => "echo"}) do
    respond(conn, Runs.send_prompt(id, "hello from LiveView"))
  end

  def sample(conn, %{"id" => id, "sample" => "permission"}) do
    respond(conn, Runs.send_prompt(id, "permission"))
  end

  def sample(conn, %{"id" => id, "sample" => "read-file"}) do
    respond(conn, Runs.send_prompt(id, "read-file"))
  end

  def sample(conn, %{"id" => id, "sample" => "write-file"}) do
    respond(conn, Runs.send_prompt(id, "write-file"))
  end

  def sample(conn, %{"id" => id, "sample" => "terminal"}) do
    respond(conn, Runs.send_prompt(id, "terminal"))
  end

  def permission(conn, %{"id" => id, "request_id" => request_id, "option_id" => option_id}) do
    respond(conn, Runs.resolve_permission(id, request_id, option_id))
  end

  defp respond(conn, :ok), do: json(conn, %{ok: true})

  defp respond(conn, {:error, reason}) do
    conn
    |> put_status(:conflict)
    |> json(%{ok: false, error: inspect(reason)})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
