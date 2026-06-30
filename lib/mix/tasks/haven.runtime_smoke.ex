defmodule Mix.Tasks.Haven.RuntimeSmoke do
  use Mix.Task

  @shortdoc "Exercises the running dev server through rendered HTTP pages"

  @moduledoc """
  Runs a deterministic smoke check against a running Haven dev server.

  This task intentionally talks to `http://127.0.0.1:4000` through HTTP instead
  of mounting LiveViews in the test process. It catches the class of failures
  where tests pass but the actual dev runtime cannot render.

      MIX_ENV=dev mix haven.runtime_smoke
      MIX_ENV=dev mix haven.runtime_smoke --base-url http://127.0.0.1:4001

  The task requires dev routes to be enabled and a server to already be running.
  It creates a short stub-backed run through `/dev/runs`, triggers a permission
  request, resolves it, and verifies the rendered inbox/run pages expose the
  mobile-first thread, decision, and evidence disclosure surfaces.
  """

  @requirements ["app.config"]

  @default_base_url "http://127.0.0.1:4000"
  @default_timeout_ms 15_000
  @poll_interval_ms 100

  @impl true
  def run(args) do
    opts = parse_args!(args)

    Mix.Task.run("haven.pending_migrations")

    base_url = opts[:base_url]
    workspace = opts[:workspace]
    timeout_ms = opts[:timeout_ms]

    Req.new(base_url: base_url, retry: false)
    |> smoke!(workspace, timeout_ms)
  end

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          base_url: :string,
          workspace: :string,
          timeout_ms: :integer
        ],
        aliases: [
          u: :base_url,
          w: :workspace,
          t: :timeout_ms
        ]
      )

    if rest != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments. Usage: mix haven.runtime_smoke [--base-url URL] [--workspace PATH]"
      )
    end

    workspace =
      opts
      |> Keyword.get(:workspace, File.cwd!())
      |> Path.expand()

    unless File.dir?(workspace) do
      Mix.raise("Workspace must be an existing directory: #{workspace}")
    end

    [
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      workspace: workspace,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    ]
  end

  defp smoke!(client, workspace, timeout_ms) do
    title = "Runtime smoke #{System.system_time(:millisecond)}"

    inbox_html = get_html!(client, "/")

    assert_contains!(inbox_html, "haven-inbox", "inbox root")
    assert_contains!(inbox_html, "new-run-form", "new run form")
    assert_contains!(inbox_html, "Manage workspaces", "workspace disclosure")
    assert_contains!(inbox_html, "Manage agents", "agent disclosure")

    run = create_run!(client, title, workspace)
    run_path = "/runs/#{run["id"]}"

    run_html =
      wait_until!(timeout_ms, "run page renders initialized thread", fn ->
        html = get_html!(client, run_path)

        if contains_all?(html, [
             "run-thread",
             "agent_initialized",
             "agent_session_started",
             "run-capability-policy",
             "run-permission-audit",
             "run-file-changes",
             "run-terminal-sessions"
           ]) do
          {:ok, html}
        else
          :retry
        end
      end)

    assert_contains!(run_html, "Filter activity", "timeline filter disclosure")
    assert_contains!(run_html, "Capability policy", "capability disclosure")
    assert_contains!(run_html, "Permission audit", "permission audit disclosure")

    sample_until_ok!(client, run["id"], "permission", timeout_ms)

    waiting_html =
      wait_until!(timeout_ms, "permission request appears", fn ->
        html = get_html!(client, run_path)

        if contains_all?(html, ["pending-permission-card", "Needs approval"]) do
          {:ok, html}
        else
          :retry
        end
      end)

    assert_contains!(waiting_html, "Technical details", "permission technical disclosure")

    resolve_permission!(client, run["id"], "1", "allow")

    resolved_html =
      wait_until!(timeout_ms, "permission resolution is rendered durably", fn ->
        html = get_html!(client, run_path)

        if contains_all?(html, ["permission_resolved", "turn_finished"]) and
             not String.contains?(html, "pending-permission-card") do
          {:ok, html}
        else
          :retry
        end
      end)

    assert_contains!(resolved_html, "run-thread", "run thread after resolution")

    Mix.shell().info("Runtime smoke passed.")
    Mix.shell().info("  base_url: #{client.options[:base_url]}")
    Mix.shell().info("  run_id: #{run["id"]}")
    Mix.shell().info("  run_url: #{client.options[:base_url]}#{run_path}")
  end

  defp get_html!(client, path) do
    response = Req.get!(client, url: path)
    assert_status!(response, 200, "GET #{path}")
    response.body
  end

  defp create_run!(client, title, workspace) do
    response =
      Req.post!(client,
        url: "/dev/runs",
        json: %{
          title: title,
          workspace: workspace,
          agent: "stub-acp"
        }
      )

    assert_status!(response, 200, "POST /dev/runs")

    body = response_body(response)

    case body do
      %{"ok" => true, "run" => %{"id" => id} = run} when is_binary(id) -> run
      other -> Mix.raise("POST /dev/runs returned unexpected body: #{inspect(other)}")
    end
  end

  defp sample_until_ok!(client, run_id, sample, timeout_ms) do
    wait_until!(timeout_ms, "sample #{sample} accepted", fn ->
      response = Req.post!(client, url: "/dev/runs/#{run_id}/sample/#{sample}")

      case {response.status, response_body(response)} do
        {200, %{"ok" => true}} -> {:ok, :sampled}
        {409, _body} -> :retry
        other -> Mix.raise("Sample #{sample} failed: #{inspect(other)}")
      end
    end)
  end

  defp resolve_permission!(client, run_id, request_id, option_id) do
    response =
      Req.post!(client, url: "/dev/runs/#{run_id}/permissions/#{request_id}/#{option_id}")

    assert_status!(
      response,
      200,
      "POST /dev/runs/#{run_id}/permissions/#{request_id}/#{option_id}"
    )

    case response_body(response) do
      %{"ok" => true} -> :ok
      other -> Mix.raise("Permission resolution returned unexpected body: #{inspect(other)}")
    end
  end

  defp wait_until!(timeout_ms, label, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until!(deadline, label, fun, nil)
  end

  defp wait_until!(deadline, label, fun, last_error) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        retry_or_raise!(deadline, label, fun, last_error)
    end
  rescue
    exception in [Req.TransportError, Req.HTTPError] ->
      retry_or_raise!(deadline, label, fun, Exception.message(exception))
  end

  defp retry_or_raise!(deadline, label, fun, last_error) do
    if System.monotonic_time(:millisecond) >= deadline do
      suffix = if last_error, do: " Last error: #{last_error}", else: ""
      Mix.raise("Timed out waiting for #{label}.#{suffix}")
    end

    Process.sleep(@poll_interval_ms)
    wait_until!(deadline, label, fun, last_error)
  end

  defp assert_status!(response, expected, label) do
    unless response.status == expected do
      Mix.raise(
        "#{label} returned #{response.status}, expected #{expected}: #{inspect(response.body)}"
      )
    end
  end

  defp assert_contains!(html, needle, label) do
    unless String.contains?(html, needle) do
      Mix.raise("Rendered HTML did not include #{label}: #{inspect(needle)}")
    end
  end

  defp contains_all?(html, needles), do: Enum.all?(needles, &String.contains?(html, &1))

  defp response_body(%Req.Response{body: body}) when is_map(body), do: body

  defp response_body(%Req.Response{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> body
    end
  end
end
