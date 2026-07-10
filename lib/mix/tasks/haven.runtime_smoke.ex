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
      MIX_ENV=dev mix haven.runtime_smoke --load-runs 3

  The task requires dev routes to be enabled and a server to already be running.
  It creates a disposable workspace by default, starts a stub-backed run through
  `/dev/runs`, triggers permission/file/terminal capability paths, resolves the
  human decisions, and verifies the rendered inbox/run pages expose the
  mobile-first thread, decision, and evidence disclosure surfaces. With
  `--load-runs N`, it also creates N additional disposable runs, drives them
  independently, and verifies long-output rendering plus cross-run isolation
  after reload.
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
    load_runs = opts[:load_runs]

    Req.new(base_url: base_url, retry: false)
    |> smoke!(workspace, timeout_ms, load_runs)
  end

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          base_url: :string,
          workspace: :string,
          timeout_ms: :integer,
          load_runs: :integer
        ],
        aliases: [
          u: :base_url,
          w: :workspace,
          t: :timeout_ms
        ]
      )

    if rest != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments. Usage: mix haven.runtime_smoke [--base-url URL] [--workspace PATH] [--load-runs N]"
      )
    end

    workspace =
      case Keyword.fetch(opts, :workspace) do
        {:ok, path} ->
          path
          |> Path.expand()
          |> tap(fn expanded ->
            unless File.dir?(expanded) do
              Mix.raise("Workspace must be an existing directory: #{expanded}")
            end

            unless File.regular?(Path.join(expanded, "README.md")) do
              Mix.raise("Workspace must include README.md for the read-file smoke: #{expanded}")
            end
          end)

        :error ->
          create_smoke_workspace!()
      end

    [
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      workspace: workspace,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      load_runs: load_runs!(Keyword.get(opts, :load_runs, 0))
    ]
  end

  defp smoke!(client, workspace, timeout_ms, load_runs) do
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

    request_id =
      trigger_pending_permission!(client, run["id"], run_path, "permission", timeout_ms)

    resolve_permission!(client, run["id"], request_id, "allow")

    permission_html =
      wait_until!(timeout_ms, "permission resolution is rendered durably", fn ->
        html = get_html!(client, run_path)

        if contains_all?(html, [
             "permission_resolved",
             "turn_finished",
             "Permission audit",
             "Requested",
             "Resolved",
             "UTC"
           ]) and not String.contains?(html, "pending-permission-card") do
          {:ok, html}
        else
          :retry
        end
      end)

    assert_contains!(permission_html, "local_user", "permission audit actor")

    read_request_id =
      trigger_pending_permission!(client, run["id"], run_path, "read-file", timeout_ms)

    resolve_permission!(client, run["id"], read_request_id, "allow")

    wait_until!(timeout_ms, "file read succeeds and renders", fn ->
      html = get_html!(client, run_path)

      if contains_all?(html, [
           "file_read_succeeded",
           "Read file: Haven runtime smoke fixture"
         ]) do
        {:ok, html}
      else
        :retry
      end
    end)

    write_request_id =
      trigger_pending_permission!(client, run["id"], run_path, "write-file", timeout_ms)

    resolve_permission!(client, run["id"], write_request_id, "allow")

    wait_until!(timeout_ms, "file write succeeds and renders", fn ->
      html = get_html!(client, run_path)

      if contains_all?(html, [
           "file_write_succeeded",
           "haven-written.txt",
           "Wrote file through Haven."
         ]) do
        {:ok, html}
      else
        :retry
      end
    end)

    unless File.read(Path.join(workspace, "haven-written.txt")) == {:ok, "written by Haven ACP\n"} do
      Mix.raise("File write smoke did not create the expected workspace file.")
    end

    sample_until_ok!(client, run["id"], "terminal", timeout_ms)

    terminal_html =
      wait_until!(timeout_ms, "terminal capability succeeds and renders", fn ->
        html = get_html!(client, run_path)

        if contains_all?(html, [
             "terminal_created",
             "terminal_output_succeeded",
             "Terminal output: hello",
             "run-terminal-session-count"
           ]) do
          {:ok, html}
        else
          :retry
        end
      end)

    assert_contains!(terminal_html, "run-thread", "run thread after terminal smoke")

    if load_runs > 0 do
      multi_run_load_smoke!(client, load_runs, timeout_ms)
    end

    Mix.shell().info("Runtime smoke passed.")
    Mix.shell().info("  base_url: #{client.options[:base_url]}")
    Mix.shell().info("  workspace: #{workspace}")
    Mix.shell().info("  run_id: #{run["id"]}")
    Mix.shell().info("  run_url: #{client.options[:base_url]}#{run_path}")

    if load_runs > 0 do
      Mix.shell().info("  load_runs: #{load_runs}")
    end
  end

  defp load_runs!(count) when is_integer(count) and count >= 0, do: count

  defp load_runs!(count) do
    Mix.raise("--load-runs must be a non-negative integer, got: #{inspect(count)}")
  end

  defp multi_run_load_smoke!(client, count, timeout_ms) do
    runs =
      1..count
      |> Enum.map(fn index ->
        workspace = create_smoke_workspace!()
        title = "Runtime load smoke #{System.system_time(:millisecond)} #{index}"
        run = create_run!(client, title, workspace)

        %{index: index, title: title, workspace: workspace, run: run, path: "/runs/#{run["id"]}"}
      end)

    Enum.each(runs, fn item ->
      sample = if rem(item.index, 2) == 1, do: "long-output", else: "echo"
      sample_until_ok!(client, item.run["id"], sample, timeout_ms)
    end)

    Enum.each(runs, fn item ->
      wait_until!(timeout_ms, "load run #{item.index} completes independently", fn ->
        html = get_html!(client, item.path)

        expected =
          if rem(item.index, 2) == 1 do
            ["run-thread", item.title, "long-output-chunk-1", "long-output-chunk-40"]
          else
            ["run-thread", item.title, "Echo: hello from LiveView"]
          end

        if contains_all?(html, expected) and isolated_from_other_load_runs?(html, item, runs) do
          {:ok, html}
        else
          :retry
        end
      end)
    end)

    reloaded_inbox = get_html!(client, "/")

    Enum.each(runs, fn item ->
      assert_contains!(reloaded_inbox, item.title, "load run #{item.index} inbox row")
    end)
  end

  defp isolated_from_other_load_runs?(html, current, runs) do
    runs
    |> Enum.reject(&(&1.run["id"] == current.run["id"]))
    |> Enum.all?(fn other ->
      not String.contains?(html, other.title) and
        not String.contains?(html, other.run["id"])
    end)
  end

  defp create_smoke_workspace! do
    path =
      Path.join(System.tmp_dir!(), "haven-runtime-smoke-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), "Haven runtime smoke fixture\n")
    path
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

  defp trigger_pending_permission!(client, run_id, run_path, sample, timeout_ms) do
    sample_until_ok!(client, run_id, sample, timeout_ms)

    waiting_html =
      wait_until!(timeout_ms, "#{sample} permission request appears", fn ->
        html = get_html!(client, run_path)

        if contains_all?(html, ["pending-permission-card", "Needs approval"]) do
          {:ok, html}
        else
          :retry
        end
      end)

    assert_contains!(waiting_html, "Review details", "permission detail disclosure")

    case Regex.run(~r/phx-value-request-id="([^"]+)"/, waiting_html, capture: :all_but_first) do
      [request_id] -> request_id
      _match -> Mix.raise("Could not find pending permission request id in rendered run page.")
    end
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
