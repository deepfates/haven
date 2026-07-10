defmodule HavenWeb.RunLive do
  use HavenWeb, :live_view

  alias Haven.AgentProbe
  alias Haven.Agents
  alias Haven.Events
  alias Haven.FileChanges
  alias Haven.PermissionAudits
  alias Haven.Runs
  alias Haven.Runs.Run
  alias Haven.TerminalSessions
  alias Haven.Workspaces

  @event_filters [
    {"all", "All"},
    {"app", "App"},
    {"user", "User"},
    {"agent", "Agent"},
    {"client", "Client"},
    {"protocol", "Protocol"},
    {"runtime", "Runtime"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Events.subscribe(id)
      Runs.subscribe()
    end

    {:ok,
     socket
     |> assign(:prompt, "")
     |> assign(:event_filter, "all")
     |> assign(:event_search, "")
     |> assign_run(id)}
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    socket =
      if socket.assigns.can_prompt? and prompt != "" do
        socket.assigns.run.id
        |> Runs.send_prompt(prompt)
        |> assign_action_result(socket)
      else
        socket
      end

    {:noreply, assign(socket, :prompt, "") |> assign_run(socket.assigns.run.id)}
  end

  def handle_event("continue_failed", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    socket =
      if socket.assigns.can_continue_failed? and prompt != "" do
        socket.assigns.run.id
        |> Runs.continue_failed_run(prompt)
        |> assign_action_result(socket)
      else
        socket
      end

    {:noreply, assign(socket, :prompt, "") |> assign_run(socket.assigns.run.id)}
  end

  def handle_event(
        "resolve_permission",
        %{"request-id" => request_id, "option-id" => option_id},
        socket
      ) do
    socket =
      socket.assigns.run.id
      |> Runs.resolve_permission(request_id, option_id)
      |> assign_action_result(socket)

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("cancel", _params, socket) do
    socket =
      if socket.assigns.can_cancel? do
        socket.assigns.run.id
        |> Runs.cancel()
        |> assign_action_result(socket)
      else
        socket
      end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("reconnect", _params, socket) do
    socket =
      if socket.assigns.can_reconnect? do
        socket.assigns.run.id
        |> Runs.reconnect_run()
        |> assign_action_result(socket)
      else
        socket
      end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("retry_last_prompt", _params, socket) do
    socket =
      if socket.assigns.can_retry_last_prompt? do
        socket.assigns.run.id
        |> Runs.retry_last_prompt()
        |> assign_action_result(socket)
      else
        socket
      end

    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_event("filter_events", %{"kind" => kind}, socket) do
    kind = if valid_event_filter?(kind), do: kind, else: "all"

    {:noreply,
     socket
     |> assign(:event_filter, kind)
     |> assign_event_projection(socket.assigns.events)}
  end

  def handle_event("search_events", %{"event_search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:event_search, normalize_event_search(query))
     |> assign_event_projection(socket.assigns.events)}
  end

  def handle_event("clear_event_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:event_search, "")
     |> assign_event_projection(socket.assigns.events)}
  end

  @impl true
  def handle_info({:event_appended, _event}, socket) do
    {:noreply, assign_run(socket, socket.assigns.run.id)}
  end

  def handle_info({:run_event_appended, %{run_id: id}}, %{assigns: %{run: %{id: id}}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:run_event_appended, _event}, socket) do
    {:noreply, assign_inbox_attention_summary(socket)}
  end

  def handle_info({:run_updated, %{id: id}}, %{assigns: %{run: %{id: id}}} = socket) do
    {:noreply, assign_run(socket, id)}
  end

  def handle_info({:run_updated, _run}, socket) do
    {:noreply, assign_inbox_attention_summary(socket)}
  end

  defp assign_action_result(:ok, socket), do: socket
  defp assign_action_result({:ok, _result}, socket), do: socket

  defp assign_action_result({:error, reason}, socket) do
    put_flash(socket, :error, action_error_message(reason))
  end

  defp assign_action_result(_result, socket), do: socket

  defp action_error_message(:not_connected) do
    "This run is not connected. Use Reconnect to attach a fresh ACP session before taking more actions."
  end

  defp action_error_message(:archived_run),
    do: "This run is archived and cannot accept new actions."

  defp action_error_message(:closed_run),
    do: "This run is closed and cannot be reconnected."

  defp action_error_message(:terminal_run),
    do: "This run is no longer active. Use the recovery controls if they are available."

  defp action_error_message(:live_run),
    do: "This run is already connected. Refresh the controls before trying that again."

  defp action_error_message(:not_failed),
    do: "This run is no longer failed. Refresh the recovery controls before trying that again."

  defp action_error_message(:no_prompt),
    do: "There is no previous prompt to retry."

  defp action_error_message(:blank_prompt),
    do: "Enter an instruction before continuing the failed run."

  defp action_error_message(:busy),
    do: "The agent is already working or waiting on a decision."

  defp action_error_message({:missing_workspace, workspace}),
    do: "Restore the missing workspace before continuing: #{workspace}"

  defp action_error_message(_reason), do: "That action could not be completed."

  defp assign_run(socket, id) do
    run = Runs.get_run!(id)
    events = Events.list_for_run(id)
    latest_event_seq = latest_event_seq(events)
    {:ok, run} = Runs.mark_viewed(run, latest_event_seq, broadcast?: false)
    file_changes = FileChanges.list_for_run(id)
    terminal_sessions = TerminalSessions.list_for_run(id)
    permission_audits = PermissionAudits.list_for_run(id)
    pending_permission = latest_pending_permission(events)
    live? = Runs.started?(run)
    workspace_summary = workspace_summary(run.workspace)
    agent_readiness = agent_readiness(run.agent, run.workspace)
    agent_probe_reports = Agents.accepted_probe_reports(run.agent)
    agent_capability_gap_reports = Agents.capability_gap_reports(run.agent)
    workspace_missing? = workspace_missing?(workspace_summary)

    socket
    |> assign(:run, run)
    |> assign(:workspace_summary, workspace_summary)
    |> assign(:workspace_missing?, workspace_missing?)
    |> assign(:agent_readiness, agent_readiness)
    |> assign(:agent_probe_reports, agent_probe_reports)
    |> assign(:agent_capability_gap_reports, agent_capability_gap_reports)
    |> assign(:capability_policy, Run.capability_policy(run.capability_policy))
    |> assign(:file_changes, file_changes)
    |> assign(:file_change_counts, file_change_counts(file_changes))
    |> assign(:permission_audits, permission_audits)
    |> assign(:terminal_sessions, terminal_sessions)
    |> assign(:terminal_session_counts, terminal_session_counts(terminal_sessions))
    |> assign(:events, events)
    |> assign(:conversation_messages, conversation_messages(events))
    |> assign(:turn_summaries, turn_summaries(events))
    |> assign(
      :run_nav_counts,
      run_nav_counts(
        events,
        pending_permission,
        permission_audits,
        file_changes,
        terminal_sessions
      )
    )
    |> assign_event_projection(events)
    |> assign(:live?, live?)
    |> assign(:can_prompt?, live? and run.status == "idle" and not workspace_missing?)
    |> assign(:can_cancel?, live? and run.status in ["initializing", "running", "waiting"])
    |> assign(:can_reconnect?, can_reconnect?(run, live?, workspace_missing?))
    |> assign(:control_notice, control_notice(run, live?, workspace_missing?))
    |> assign(:prompt_disabled_reason, prompt_disabled_reason(run, live?, workspace_missing?))
    |> assign(:cancel_disabled_reason, cancel_disabled_reason(run, live?))
    |> assign(:last_user_prompt, last_user_prompt(events))
    |> assign(
      :can_retry_last_prompt?,
      can_retry_last_prompt?(run, events) and not workspace_missing?
    )
    |> assign(:can_continue_failed?, can_continue_failed?(run) and not workspace_missing?)
    |> assign(:recovery_attention, recovery_attention(run, live?, workspace_missing?))
    |> assign(:latest_failure_summary, latest_failure_summary(events))
    |> assign(:pending_permission, pending_permission)
    |> assign_inbox_attention_summary()
  end

  defp assign_inbox_attention_summary(socket) do
    summary = Runs.attention_summary(exclude_run_id: socket.assigns.run.id)
    previous_summary = socket.assigns[:inbox_attention_summary]

    socket
    |> assign(:inbox_attention_summary, summary)
    |> assign(:page_title, run_page_title(socket.assigns.run, summary))
    |> maybe_push_attention_notification(previous_summary, summary)
  end

  defp run_page_title(run, %{needs_you: needs_you}) when needs_you > 0 do
    "(#{needs_you}) #{run.title} - Haven"
  end

  defp run_page_title(run, %{unread_runs: unread_runs}) when unread_runs > 0 do
    "(#{unread_runs}) #{run.title} - Haven"
  end

  defp run_page_title(run, _summary), do: "#{run.title} - Haven"

  defp inbox_attention_badge(%{needs_you: needs_you}) when needs_you > 0 do
    needs_you_label(needs_you)
  end

  defp inbox_attention_badge(%{unread_runs: unread_runs}) when unread_runs > 0 do
    pluralize_count(unread_runs, "updated run")
  end

  defp inbox_attention_badge(_summary), do: nil

  defp inbox_attention_title(%{needs_you: needs_you} = summary) when needs_you > 0 do
    [
      attention_count(Map.get(summary, :decisions, 0), "decision"),
      attention_count(Map.get(summary, :recoveries, 0), "recovery"),
      attention_count(Map.get(summary, :interruptions, 0), "interruption"),
      attention_count(Map.get(summary, :workspaces, 0), "workspace"),
      attention_count(Map.get(summary, :unread_events, 0), "new event")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp inbox_attention_title(%{unread_runs: unread_runs, unread_events: unread_events})
       when unread_runs > 0 do
    [
      pluralize_count(unread_runs, "updated run"),
      attention_count(unread_events, "new event")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp inbox_attention_title(_summary), do: nil

  defp attention_count(0, _word), do: nil
  defp attention_count(count, word), do: pluralize_count(count, word)

  defp needs_you_label(1), do: "1 run needs you"
  defp needs_you_label(count), do: "#{count} runs need you"

  defp maybe_push_attention_notification(socket, nil, _current), do: socket

  defp maybe_push_attention_notification(socket, previous, current) do
    if attention_increased?(previous, current) do
      push_event(socket, "haven_attention_changed", attention_notification_payload(current, "/"))
    else
      socket
    end
  end

  defp attention_increased?(previous, current) do
    (current.needs_you > 0 and current.needs_you > previous.needs_you) or
      (current.unread_events > 0 and current.unread_events > previous.unread_events) or
      (current.unread_runs > 0 and current.unread_runs > previous.unread_runs)
  end

  defp attention_notification_payload(%{needs_you: needs_you} = summary, url)
       when needs_you > 0 do
    %{
      title: "Haven: #{needs_you_label(needs_you)}",
      body:
        [
          attention_count(summary.decisions, "decision"),
          attention_count(summary.recoveries, "recovery"),
          attention_count(Map.get(summary, :interruptions, 0), "interruption"),
          attention_count(Map.get(summary, :workspaces, 0), "workspace"),
          attention_count(summary.unread_events, "new event")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · "),
      url: url,
      urgency: "needs_you"
    }
  end

  defp attention_notification_payload(%{unread_runs: unread_runs} = summary, url) do
    %{
      title: "Haven: #{pluralize_count(unread_runs, "updated run")}",
      body: attention_count(summary.unread_events, "new event") || "New activity",
      url: url,
      urgency: "updated"
    }
  end

  defp latest_event_seq(events) do
    events
    |> Enum.map(& &1.seq)
    |> Enum.max(fn -> 0 end)
  end

  defp run_nav_counts(
         events,
         pending_permission,
         permission_audits,
         file_changes,
         terminal_sessions
       ) do
    decision_count = max(length(permission_audits), if(pending_permission, do: 1, else: 0))

    evidence_count =
      length(events) + length(permission_audits) + length(file_changes) +
        length(terminal_sessions)

    %{
      thread: conversation_count(events),
      decisions: decision_count,
      evidence: evidence_count
    }
  end

  defp conversation_count(events) do
    Enum.count(events, &(&1.type in ["user_message", "agent_message_chunk"]))
  end

  defp assign_event_projection(socket, events) do
    filter = socket.assigns[:event_filter] || "all"
    search = socket.assigns[:event_search] || ""
    timeline_entries = timeline_entries(events, filter, search)

    socket
    |> assign(:event_filters, @event_filters)
    |> assign(:event_counts, event_counts(events))
    |> assign(:event_search, search)
    |> assign(:timeline_entries, timeline_entries)
  end

  defp valid_event_filter?(kind) do
    Enum.any?(@event_filters, fn {filter, _label} -> filter == kind end)
  end

  defp filter_events(events, "all"), do: events

  defp filter_events(events, filter) do
    Enum.filter(events, &(event_kind(&1.type) == filter))
  end

  defp event_counts(events) do
    counts =
      events
      |> Enum.map(&event_kind(&1.type))
      |> Enum.frequencies()

    Map.put(counts, "all", length(events))
  end

  defp timeline_entries(events, filter, search) do
    paired_results = paired_tool_results(events)
    paired_result_seqs = MapSet.new(Map.values(paired_results), & &1.seq)

    events
    |> filter_events(filter)
    |> Enum.flat_map(fn event ->
      cond do
        event.type == "tool_call" ->
          [%{event: event, result_event: Map.get(paired_results, tool_call_id(event.payload))}]

        event.type == "tool_call_update" and MapSet.member?(paired_result_seqs, event.seq) ->
          []

        true ->
          [%{event: event, result_event: nil}]
      end
    end)
    |> filter_timeline_entries(search)
  end

  defp normalize_event_search(query) when is_binary(query), do: String.trim(query)
  defp normalize_event_search(_query), do: ""

  defp filter_timeline_entries(entries, ""), do: entries

  defp filter_timeline_entries(entries, search) do
    normalized_search = String.downcase(search)

    Enum.filter(entries, fn entry ->
      entry
      |> timeline_entry_search_text()
      |> String.downcase()
      |> String.contains?(normalized_search)
    end)
  end

  defp timeline_entry_search_text(%{event: event, result_event: result_event}) do
    [
      event.type,
      event_kind_label(event.type),
      event_search_label(event),
      safe_json(event.payload),
      result_event && result_event.type,
      result_event && event_search_label(result_event),
      result_event && safe_json(result_event.payload)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp event_search_label(%{type: "tool_call", payload: payload}) do
    [
      "Tool call",
      tool_call_kind_label(payload["kind"] || "tool"),
      payload["title"],
      tool_call_path(payload),
      get_in(payload, ["rawInput", "command"])
    ]
    |> search_label()
  end

  defp event_search_label(%{type: "tool_call_update", payload: payload}) do
    [
      "Tool result",
      tool_result_label(payload["status"], tool_call_exit_code(payload)),
      payload["title"],
      tool_call_output(payload)
    ]
    |> search_label()
  end

  defp event_search_label(%{type: type, payload: payload})
       when type in [
              "agent_start_failed",
              "agent_protocol_failed",
              "agent_process_down"
            ] do
    [
      "Runtime failure",
      runtime_failure_title(type),
      runtime_failure_reason(payload)
    ]
    |> search_label()
  end

  defp event_search_label(%{type: "turn_retry_requested"}), do: "Retry requested"
  defp event_search_label(%{type: "turn_continue_requested"}), do: "Continue requested"
  defp event_search_label(%{type: "turn_failed"}), do: "Turn failed"
  defp event_search_label(%{type: "run_reconnect_requested"}), do: "Reconnect requested"

  defp event_search_label(%{type: type, payload: payload})
       when type in ["permission_resolved", "permission_resolution_ignored"] do
    [
      "Permission decision",
      if(type == "permission_resolution_ignored",
        do: "Stale decision ignored",
        else: "Decision recorded"
      ),
      payload["option_id"],
      payload["actor"],
      payload["outcome"],
      payload["reason"]
    ]
    |> search_label()
  end

  defp event_search_label(%{type: type})
       when type in [
              "file_read_requested",
              "file_read_succeeded",
              "file_read_failed",
              "file_read_denied",
              "file_write_requested",
              "file_write_succeeded",
              "file_write_failed",
              "file_write_denied",
              "terminal_create_requested",
              "terminal_created",
              "terminal_create_denied",
              "terminal_create_failed",
              "terminal_wait_requested",
              "terminal_wait_succeeded",
              "terminal_wait_failed",
              "terminal_output_requested",
              "terminal_output_succeeded",
              "terminal_output_failed",
              "terminal_release_requested",
              "terminal_released",
              "terminal_release_failed",
              "terminal_kill_requested",
              "terminal_kill_succeeded",
              "terminal_kill_failed"
            ] do
    [client_event_tag(type), client_event_title(type), client_event_status(type)]
    |> search_label()
  end

  defp event_search_label(_event), do: nil

  defp search_label(parts) do
    parts
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp safe_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp paired_tool_results(events) do
    started_ids =
      events
      |> Enum.filter(&(&1.type == "tool_call"))
      |> MapSet.new(&tool_call_id(&1.payload))

    events
    |> Enum.filter(&(&1.type == "tool_call_update"))
    |> Enum.reduce(%{}, fn event, acc ->
      id = tool_call_id(event.payload)

      if id && MapSet.member?(started_ids, id) do
        Map.put_new(acc, id, event)
      else
        acc
      end
    end)
  end

  defp can_reconnect?(_run, _live?, true), do: false

  defp can_reconnect?(run, live?, false) do
    is_nil(run.archived_at) and (run.status == "failed" or (not live? and run.status != "closed"))
  end

  defp can_retry_last_prompt?(%{status: "failed", archived_at: nil}, events),
    do: is_binary(last_user_prompt(events))

  defp can_retry_last_prompt?(_run, _events), do: false

  defp can_continue_failed?(%{status: "failed", archived_at: nil}), do: true
  defp can_continue_failed?(_run), do: false

  defp control_notice(%{archived_at: archived_at}, _live?, _workspace_missing?)
       when not is_nil(archived_at) do
    "This run is archived. Its history is review-only and cannot accept prompts, reconnects, restarts, or cancellation."
  end

  defp control_notice(_run, _live?, true) do
    "This run's workspace is missing. Restore the folder before sending prompts, reconnecting, or restarting."
  end

  defp control_notice(%{status: "failed"}, _live?, _workspace_missing?) do
    "This run failed. Use the recovery options above to continue, retry, or restart."
  end

  defp control_notice(%{status: "closed"}, _live?, _workspace_missing?) do
    "This run is closed. Its history is available, but it cannot accept prompts."
  end

  defp control_notice(_run, false, _workspace_missing?) do
    "This run is not connected. Reconnect it before sending another prompt."
  end

  defp control_notice(%{status: "waiting"}, _live?, _workspace_missing?) do
    "Waiting for your decision before this run can accept another prompt."
  end

  defp control_notice(%{status: status}, _live?, _workspace_missing?)
       when status in ["initializing", "running"] do
    "A turn is already in progress. You can cancel it, then send a new prompt."
  end

  defp control_notice(_run, _live?, _workspace_missing?), do: nil

  defp prompt_disabled_reason(_run, _live?, true),
    do: "Restore the missing workspace before messaging this run."

  defp prompt_disabled_reason(%{status: "idle"}, true, false), do: nil

  defp prompt_disabled_reason(run, live?, workspace_missing?),
    do: control_notice(run, live?, workspace_missing?)

  defp cancel_disabled_reason(%{status: status}, true)
       when status in ["initializing", "running", "waiting"],
       do: nil

  defp cancel_disabled_reason(%{archived_at: archived_at}, _live?) when not is_nil(archived_at) do
    "This run is archived. There is no live turn to cancel."
  end

  defp cancel_disabled_reason(%{status: "failed"}, _live?) do
    "This run failed. Restart it instead of cancelling."
  end

  defp cancel_disabled_reason(%{status: "closed"}, _live?) do
    "This run is closed. There is no active turn to cancel."
  end

  defp cancel_disabled_reason(_run, false) do
    "This run is not connected. There is no live turn to cancel."
  end

  defp cancel_disabled_reason(_run, _live?), do: "There is no active turn to cancel."

  defp header_status_label(%{status: status}, false) when status in ["initializing", "running"],
    do: "Interrupted"

  defp header_status_label(run, _live?), do: run.status

  defp header_status_title(%{status: status}, false) when status in ["initializing", "running"] do
    "Persisted status is #{status}, but no live agent process is attached."
  end

  defp header_status_title(run, live?) do
    process_state = if live?, do: "connected", else: "not connected"
    "Persisted status is #{run.status}; process is #{process_state}."
  end

  defp header_status_class(%{status: status}, false) when status in ["initializing", "running"] do
    "inline-flex items-center rounded-full border border-rose-200 bg-rose-50 px-3 py-1 text-sm font-medium text-rose-700"
  end

  defp header_status_class(_run, _live?) do
    "inline-flex items-center rounded-full border border-zinc-200 bg-white px-3 py-1 text-sm font-medium text-zinc-700"
  end

  defp recovery_attention(%{archived_at: archived_at}, _live?, _workspace_missing?)
       when not is_nil(archived_at),
       do: nil

  defp recovery_attention(run, _live?, true) do
    %{
      title: "Workspace is missing",
      body:
        "Haven can still show the saved history, but it cannot safely reconnect this run until the workspace exists again at #{run.workspace}.",
      action: nil
    }
  end

  defp recovery_attention(%{status: "failed"}, _live?, _workspace_missing?) do
    %{
      title: "Run failed",
      body:
        "The agent process is no longer usable. Restart starts a fresh ACP session while keeping this run history intact.",
      action: "Restart"
    }
  end

  defp recovery_attention(%{status: status}, false, _workspace_missing?)
       when status in ["initializing", "running"] do
    %{
      title: "Turn was interrupted",
      body:
        "This run has an unfinished saved turn, but no live agent process is attached. Reconnect records that old turn as failed, then starts a fresh ACP session for this run.",
      action: "Reconnect"
    }
  end

  defp recovery_attention(%{status: status}, false, _workspace_missing?)
       when status != "closed" do
    %{
      title: "Run is not connected",
      body:
        "The durable history is available, but no live agent process is attached. Reconnect starts a fresh ACP session for this run.",
      action: "Reconnect"
    }
  end

  defp recovery_attention(_run, _live?, _workspace_missing?), do: nil

  defp recovery_option_rows(assigns) do
    [
      assigns.can_continue_failed? &&
        %{
          id: "continue",
          label: "Continue",
          description: "Start a fresh ACP session and send a new instruction."
        },
      assigns.can_retry_last_prompt? &&
        %{
          id: "retry",
          label: "Retry",
          description: "Start a fresh ACP session and resend the last user prompt."
        },
      recovery_action_row(assigns.recovery_attention)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp recovery_action_row(%{action: "Restart"}) do
    %{
      id: "restart",
      label: "Restart",
      description: "Start a fresh ACP session without sending a prompt yet."
    }
  end

  defp recovery_action_row(%{title: "Turn was interrupted", action: "Reconnect"}) do
    %{
      id: "reconnect",
      label: "Reconnect",
      description: "Mark the unfinished saved turn failed, then attach a fresh ACP session."
    }
  end

  defp recovery_action_row(%{action: "Reconnect"}) do
    %{
      id: "reconnect",
      label: "Reconnect",
      description: "Attach a fresh ACP session to this saved run history."
    }
  end

  defp recovery_action_row(_attention), do: nil

  defp recovery_action_title("Restart"), do: "Start a fresh ACP session without sending a prompt."
  defp recovery_action_title("Reconnect"), do: "Attach a fresh ACP session to this run."
  defp recovery_action_title(_action), do: nil

  defp latest_failure_summary(events) do
    events
    |> Enum.reverse()
    |> Enum.find(&failure_event?/1)
    |> case do
      nil -> nil
      event -> failure_summary(event)
    end
  end

  defp failure_event?(%{type: type})
       when type in [
              "turn_failed",
              "agent_start_failed",
              "agent_protocol_failed",
              "agent_process_down",
              "agent_process_exited"
            ],
       do: true

  defp failure_event?(_event), do: false

  defp failure_summary(%{type: "turn_failed", seq: seq, payload: payload}) do
    %{
      seq: seq,
      title: "Turn failed",
      reason: format_client_value(payload["error"] || "unknown turn failure")
    }
  end

  defp failure_summary(%{type: "agent_process_exited", seq: seq, payload: payload}) do
    %{
      seq: seq,
      title: "Agent process exited",
      reason: "Exit status #{format_client_value(payload["status"] || "unknown")}"
    }
  end

  defp failure_summary(%{type: type, seq: seq, payload: payload}) do
    %{
      seq: seq,
      title: runtime_failure_title(type),
      reason: runtime_failure_reason(payload)
    }
  end

  defp latest_pending_permission(events) do
    resolved =
      events
      |> Enum.filter(&(&1.type == "permission_resolved"))
      |> MapSet.new(&to_string(&1.payload["request_id"]))

    events
    |> Enum.filter(&(&1.type == "permission_requested"))
    |> Enum.reject(&MapSet.member?(resolved, to_string(&1.payload["request_id"])))
    |> List.last()
  end

  defp last_user_prompt(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: "user_message", payload: %{"text" => text}} when is_binary(text) -> text
      _event -> nil
    end)
  end

  defp conversation_messages(events) do
    events
    |> Enum.reduce([], fn
      %{type: "user_message", seq: seq, inserted_at: inserted_at, payload: %{"text" => text}}, acc
      when is_binary(text) ->
        [%{role: "user", seq: seq, inserted_at: inserted_at, text: text} | acc]

      %{
        type: "agent_message_chunk",
        seq: seq,
        inserted_at: inserted_at,
        payload: %{"text" => text}
      },
      [%{role: "agent"} = previous | rest]
      when is_binary(text) ->
        [
          %{previous | text: previous.text <> text, last_seq: seq, inserted_at: inserted_at}
          | rest
        ]

      %{
        type: "agent_message_chunk",
        seq: seq,
        inserted_at: inserted_at,
        payload: %{"text" => text}
      },
      acc
      when is_binary(text) ->
        [
          %{role: "agent", seq: seq, last_seq: seq, inserted_at: inserted_at, text: text}
          | acc
        ]

      _event, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp conversation_message_class("user") do
    "ml-auto max-w-[88%] rounded-2xl rounded-br-md bg-zinc-950 px-4 py-3 text-sm text-white sm:max-w-[75%]"
  end

  defp conversation_message_class("agent") do
    "mr-auto max-w-[88%] rounded-2xl rounded-bl-md border border-zinc-200 bg-white px-4 py-3 text-sm text-zinc-900 shadow-sm sm:max-w-[75%]"
  end

  defp conversation_message_label("user"), do: "You"
  defp conversation_message_label("agent"), do: "Agent"

  defp conversation_message_label_class("user"), do: "text-zinc-300"
  defp conversation_message_label_class("agent"), do: "text-zinc-500"

  defp turn_summaries(events) do
    {summaries, current} =
      Enum.reduce(events, {[], nil}, fn event, {summaries, current} ->
        case {event.type, current} do
          {"turn_started", nil} ->
            {summaries, new_turn_summary(event)}

          {"turn_started", current} ->
            {[current | summaries], new_turn_summary(event)}

          {"user_message", current} when not is_nil(current) ->
            {summaries, %{current | prompt: current.prompt || event.payload["text"]}}

          {"agent_message_chunk", current} when not is_nil(current) ->
            {summaries, append_turn_agent_text(current, event.payload["text"])}

          {"tool_call", current} when not is_nil(current) ->
            {summaries, update_in(current.tool_calls, &(&1 + 1))}

          {"permission_requested", current} when not is_nil(current) ->
            {summaries, update_in(current.decisions, &(&1 + 1))}

          {type, current} when not is_nil(current) ->
            cond do
              type in ["turn_finished", "turn_failed", "turn_cancelled"] ->
                {[finish_turn_summary(current, event) | summaries], nil}

              String.starts_with?(type, "file_") ->
                {summaries, update_in(current.file_events, &(&1 + 1))}

              String.starts_with?(type, "terminal_") ->
                {summaries, update_in(current.terminal_events, &(&1 + 1))}

              true ->
                {summaries, current}
            end

          _event_without_turn ->
            {summaries, current}
        end
      end)

    summaries = if current, do: [current | summaries], else: summaries

    summaries
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {summary, index} -> Map.put(summary, :index, index) end)
  end

  defp new_turn_summary(event) do
    %{
      index: nil,
      started_seq: event.seq,
      ended_seq: nil,
      started_at: event.inserted_at,
      ended_at: nil,
      status: "running",
      prompt: event.payload["prompt"],
      agent_text: "",
      tool_calls: 0,
      decisions: 0,
      file_events: 0,
      terminal_events: 0,
      error: nil
    }
  end

  defp append_turn_agent_text(summary, text) when is_binary(text) do
    %{summary | agent_text: summary.agent_text <> text}
  end

  defp append_turn_agent_text(summary, _text), do: summary

  defp finish_turn_summary(summary, event) do
    %{
      summary
      | ended_seq: event.seq,
        ended_at: event.inserted_at,
        status: turn_terminal_status(event.type),
        error: event.payload["error"]
    }
  end

  defp turn_terminal_status("turn_finished"), do: "completed"
  defp turn_terminal_status("turn_failed"), do: "failed"
  defp turn_terminal_status("turn_cancelled"), do: "cancelled"

  defp turn_sequence_label(%{ended_seq: nil, started_seq: started_seq}), do: "##{started_seq}+"

  defp turn_sequence_label(%{started_seq: started_seq, ended_seq: ended_seq}) do
    "##{started_seq}-#{ended_seq}"
  end

  defp turn_time_label(%{ended_at: nil, started_at: started_at}) do
    Calendar.strftime(started_at, "%H:%M:%S")
  end

  defp turn_time_label(%{started_at: started_at, ended_at: ended_at}) do
    Calendar.strftime(started_at, "%H:%M:%S") <> "-" <> Calendar.strftime(ended_at, "%H:%M:%S")
  end

  defp turn_status_label("completed"), do: "Completed"
  defp turn_status_label("failed"), do: "Failed"
  defp turn_status_label("cancelled"), do: "Cancelled"
  defp turn_status_label("running"), do: "Running"

  defp turn_status_class("completed") do
    "inline-flex rounded-full border border-emerald-200 bg-emerald-50 px-2 py-0.5 text-[11px] font-semibold uppercase text-emerald-700"
  end

  defp turn_status_class("failed") do
    "inline-flex rounded-full border border-rose-200 bg-rose-50 px-2 py-0.5 text-[11px] font-semibold uppercase text-rose-700"
  end

  defp turn_status_class("cancelled") do
    "inline-flex rounded-full border border-zinc-300 bg-zinc-100 px-2 py-0.5 text-[11px] font-semibold uppercase text-zinc-700"
  end

  defp turn_status_class("running") do
    "inline-flex rounded-full border border-sky-200 bg-sky-50 px-2 py-0.5 text-[11px] font-semibold uppercase text-sky-700"
  end

  defp turn_prompt_preview(nil), do: "No user prompt recorded"
  defp turn_prompt_preview(""), do: "No user prompt recorded"
  defp turn_prompt_preview(text), do: String.slice(text, 0, 220)

  defp turn_agent_preview(""), do: "No agent response recorded"
  defp turn_agent_preview(text), do: String.slice(text, 0, 220)

  defp event(assigns) do
    assigns =
      assigns
      |> assign(:event_kind, event_kind(assigns.event.type))
      |> assign(:event_kind_label, event_kind_label(assigns.event.type))
      |> assign_new(:result_event, fn -> nil end)
      |> assign_new(:permission_audits, fn -> [] end)

    ~H"""
    <article
      id={"event-#{@event.seq}"}
      data-event-kind={@event_kind}
      class={event_card_class(@event_kind)}
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <span class="font-mono text-xs uppercase text-zinc-500">
            {event_sequence_label(@event, @result_event)} · {event_type_label(@event, @result_event)}
          </span>
          <span class={event_kind_class(@event_kind)}>
            {@event_kind_label}
          </span>
        </div>
        <span class="text-xs text-zinc-400">
          {Calendar.strftime(@event.inserted_at, "%H:%M:%S")}
        </span>
      </div>

      <div class="mt-2">
        <%= case @event.type do %>
          <% "user_message" -> %>
            <p class="whitespace-pre-wrap">{@event.payload["text"]}</p>
          <% "agent_message_chunk" -> %>
            <p class="whitespace-pre-wrap text-sky-700">{@event.payload["text"]}</p>
          <% "tool_call" -> %>
            <.tool_call_event payload={@event.payload} />
            <div
              :if={@result_event}
              id={"tool-call-result-#{@event.seq}"}
              class="mt-4 border-t border-zinc-200 pt-4"
            >
              <.tool_call_update_event payload={@result_event.payload} />
            </div>
          <% "tool_call_update" -> %>
            <.tool_call_update_event payload={@event.payload} />
          <% "agent_thought_redacted" -> %>
            <p class="font-semibold text-zinc-900">Agent thought redacted</p>
            <p class="mt-1 text-sm text-zinc-600">
              Haven preserved that private agent reasoning occurred without storing its raw text.
            </p>
          <% "permission_requested" -> %>
            <p class="font-semibold">
              {get_in(@event.payload, ["toolCall", "title"]) || "Permission requested"}
            </p>
            <pre class="mt-2 overflow-x-auto rounded-md bg-zinc-100 p-3 text-xs text-zinc-700"><%= Jason.encode!(get_in(@event.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
          <% type when type in ["permission_resolved", "permission_resolution_ignored"] -> %>
            <.permission_resolution_event
              event={@event}
              audit={permission_audit_for_event(@permission_audits, @event)}
            />
          <% type
             when type in [
                    "file_read_requested",
                    "file_read_succeeded",
                    "file_read_failed",
                    "file_read_denied",
                    "file_write_requested",
                    "file_write_succeeded",
                    "file_write_failed",
                    "file_write_denied",
                    "terminal_create_requested",
                    "terminal_created",
                    "terminal_create_denied",
                    "terminal_create_failed",
                    "terminal_wait_requested",
                    "terminal_wait_succeeded",
                    "terminal_wait_failed",
                    "terminal_output_requested",
                    "terminal_output_succeeded",
                    "terminal_output_failed",
                    "terminal_release_requested",
                    "terminal_released",
                    "terminal_release_failed",
                    "terminal_kill_requested",
                    "terminal_kill_succeeded",
                    "terminal_kill_failed"
                  ] -> %>
            <.client_capability_event seq={@event.seq} type={@event.type} payload={@event.payload} />
          <% "run_reconnect_requested" -> %>
            <p class="font-semibold text-zinc-900">Reconnect requested</p>
            <p class="mt-1 text-sm text-zinc-600">
              Previous status: {@event.payload["previous_status"] || "unknown"}
            </p>
          <% "turn_retry_requested" -> %>
            <p class="font-semibold text-zinc-900">Retry requested</p>
            <p class="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
              {@event.payload["prompt"] || "Last prompt"}
            </p>
          <% "turn_continue_requested" -> %>
            <p class="font-semibold text-zinc-900">Continue requested</p>
            <p class="mt-1 whitespace-pre-wrap text-sm text-zinc-600">
              {@event.payload["prompt"] || "Next prompt"}
            </p>
          <% "turn_failed" -> %>
            <p class="font-semibold text-rose-700">Turn failed</p>
            <p class="mt-1 text-sm text-zinc-600">
              {@event.payload["error"] || "unknown error"}
            </p>
            <p
              :if={@event.payload["actor"]}
              class="mt-1 text-xs uppercase tracking-wide text-zinc-500"
            >
              {@event.payload["actor"]}
            </p>
          <% type
             when type in [
                    "agent_start_failed",
                    "agent_protocol_failed",
                    "agent_process_down"
                  ] -> %>
            <.runtime_failure_event seq={@event.seq} type={@event.type} payload={@event.payload} />
          <% _ -> %>
            <pre class="overflow-x-auto rounded-md bg-zinc-100 p-3 text-xs text-zinc-700"><%= Jason.encode!(@event.payload, pretty: true) %></pre>
        <% end %>
      </div>
    </article>
    """
  end

  defp runtime_failure_event(assigns) do
    assigns =
      assigns
      |> assign(:title, runtime_failure_title(assigns.type))
      |> assign(:reason, runtime_failure_reason(assigns.payload))
      |> assign(:fields, runtime_failure_fields(assigns.type, assigns.payload))

    ~H"""
    <div id={"runtime-failure-#{@seq}"} class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-rose-700 px-2 py-1 text-xs font-semibold uppercase text-white">
          Runtime failure
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
        <span class={client_event_status_class("Failed")}>
          Failed
        </span>
      </div>

      <p
        id={"runtime-failure-#{@seq}-reason"}
        class="whitespace-pre-wrap text-sm font-medium text-rose-700"
      >
        {@reason}
      </p>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :for={field <- @fields} id={"runtime-failure-#{@seq}-#{field.id}"} class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">{field.label}</dt>
          <dd class="truncate font-mono text-xs">{field.value}</dd>
        </div>
      </dl>

      <details class="rounded-md border border-zinc-200 bg-zinc-50 p-3">
        <summary class="cursor-pointer text-xs font-semibold uppercase text-zinc-500">
          Event payload
        </summary>
        <pre class="mt-2 max-h-48 overflow-auto text-xs text-zinc-700"><%= Jason.encode!(@payload, pretty: true) %></pre>
      </details>
    </div>
    """
  end

  defp client_capability_event(assigns) do
    assigns =
      assigns
      |> assign(:title, client_event_title(assigns.type))
      |> assign(:status, client_event_status(assigns.type))
      |> assign(:tag, client_event_tag(assigns.type))
      |> assign(:fields, client_event_fields(assigns.type, assigns.payload))
      |> assign(:error, client_event_error(assigns.payload))

    ~H"""
    <div class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-amber-600 px-2 py-1 text-xs font-semibold uppercase text-white">
          {@tag}
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
        <span class={client_event_status_class(@status)}>
          {@status}
        </span>
      </div>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :for={field <- @fields} id={"client-event-#{@seq}-#{field.id}"} class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">{field.label}</dt>
          <dd class="truncate font-mono text-xs">{field.value}</dd>
        </div>
      </dl>

      <p :if={@error} id={"client-event-#{@seq}-error"} class="text-sm font-medium text-rose-700">
        {@error}
      </p>
    </div>
    """
  end

  defp permission_resolution_event(assigns) do
    assigns =
      assigns
      |> assign(:title, permission_resolution_title(assigns.event, assigns.audit))
      |> assign(:status, permission_resolution_status(assigns.event, assigns.audit))
      |> assign(:fields, permission_resolution_fields(assigns.event, assigns.audit))

    ~H"""
    <div id={"permission-decision-#{@event.seq}"} class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-amber-600 px-2 py-1 text-xs font-semibold uppercase text-white">
          Decision
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
        <span class={permission_status_class(@status)}>
          {@status}
        </span>
      </div>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div
          :for={field <- @fields}
          id={"permission-decision-#{@event.seq}-#{field.id}"}
          class="min-w-0"
        >
          <dt class="text-xs font-semibold uppercase text-zinc-500">{field.label}</dt>
          <dd class="truncate font-mono text-xs">{field.value}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp tool_call_event(assigns) do
    assigns =
      assigns
      |> assign(:kind, assigns.payload["kind"] || "tool")
      |> assign(:title, assigns.payload["title"] || "Tool call")
      |> assign(:path, tool_call_path(assigns.payload))
      |> assign(:command, get_in(assigns.payload, ["rawInput", "command"]))
      |> assign(
        :cwd,
        get_in(assigns.payload, ["rawInput", "cwd"]) ||
          get_in(assigns.payload, ["_meta", "terminal_info", "cwd"])
      )
      |> assign(:status, assigns.payload["status"])

    ~H"""
    <div class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-zinc-950 px-2 py-1 text-xs font-semibold uppercase text-white">
          {tool_call_kind_label(@kind)}
        </span>
        <p class="min-w-0 font-semibold text-zinc-900">{@title}</p>
      </div>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :if={@path} id="tool-call-path" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Path</dt>
          <dd class="truncate font-mono text-xs">{@path}</dd>
        </div>
        <div :if={@command} id="tool-call-command" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Command</dt>
          <dd class="truncate font-mono text-xs">{@command}</dd>
        </div>
        <div :if={@cwd} id="tool-call-cwd" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Working directory</dt>
          <dd class="truncate font-mono text-xs">{@cwd}</dd>
        </div>
        <div :if={@status} id="tool-call-status" class="min-w-0">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Status</dt>
          <dd class="font-mono text-xs">{@status}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp tool_call_update_event(assigns) do
    assigns =
      assigns
      |> assign(:title, assigns.payload["title"])
      |> assign(:status, assigns.payload["status"])
      |> assign(:exit_code, tool_call_exit_code(assigns.payload))
      |> assign(:output, tool_call_output(assigns.payload))

    ~H"""
    <div class="space-y-2">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-md bg-emerald-700 px-2 py-1 text-xs font-semibold uppercase text-white">
          Tool result
        </span>
        <p class="font-semibold text-zinc-900">
          {tool_result_label(@status, @exit_code)}
        </p>
      </div>
      <p :if={@title} class="text-sm font-medium text-zinc-800">{@title}</p>

      <dl class="grid gap-2 text-sm text-zinc-700 sm:grid-cols-2">
        <div :if={@status} id="tool-result-status">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Status</dt>
          <dd class="font-mono text-xs">{@status}</dd>
        </div>
        <div :if={!is_nil(@exit_code)} id="tool-result-exit-code">
          <dt class="text-xs font-semibold uppercase text-zinc-500">Exit code</dt>
          <dd class="font-mono text-xs">{@exit_code}</dd>
        </div>
      </dl>

      <pre
        :if={@output}
        id="tool-result-output"
        class="max-h-48 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
      ><%= @output %></pre>
    </div>
    """
  end

  defp event_kind("user_message"), do: "user"
  defp event_kind("agent_message_chunk"), do: "agent"

  defp event_kind(type)
       when type in [
              "tool_call",
              "tool_call_update",
              "plan_update",
              "agent_thought_redacted",
              "current_mode_update"
            ] do
    "protocol"
  end

  defp event_kind("agent_update_ignored"), do: "protocol"

  defp event_kind(type)
       when type in [
              "permission_requested",
              "permission_resolved",
              "permission_resolution_ignored",
              "capability_policy_applied",
              "file_read_requested",
              "file_read_succeeded",
              "file_read_failed",
              "file_read_denied",
              "file_write_requested",
              "file_write_succeeded",
              "file_write_failed",
              "file_write_denied",
              "terminal_create_requested",
              "terminal_created",
              "terminal_create_denied",
              "terminal_create_failed",
              "terminal_wait_requested",
              "terminal_wait_succeeded",
              "terminal_wait_failed",
              "terminal_output_requested",
              "terminal_output_succeeded",
              "terminal_output_failed",
              "terminal_release_requested",
              "terminal_released",
              "terminal_release_failed",
              "terminal_kill_requested",
              "terminal_kill_succeeded",
              "terminal_kill_failed"
            ] do
    "client"
  end

  defp event_kind(type)
       when type in [
              "agent_process_started",
              "agent_process_exited",
              "agent_process_down",
              "agent_initialized",
              "agent_session_started",
              "agent_session_loaded",
              "session_load_skipped",
              "session_load_failed",
              "session_mode_changed",
              "session_mode_rejected",
              "session_mode_failed",
              "agent_start_failed",
              "agent_protocol_failed"
            ] do
    "runtime"
  end

  defp event_kind(_type), do: "app"

  defp event_kind_label("user_message"), do: "User"
  defp event_kind_label("agent_message_chunk"), do: "Agent"

  defp event_kind_label(type) do
    case event_kind(type) do
      "app" -> "App"
      "client" -> "Client request"
      "protocol" -> "Protocol"
      "runtime" -> "Runtime"
      kind -> String.capitalize(kind)
    end
  end

  defp client_event_title(type) do
    cond do
      String.starts_with?(type, "file_read_") -> "Read file"
      String.starts_with?(type, "file_write_") -> "Write file"
      type == "terminal_created" -> "Create terminal"
      type == "terminal_released" -> "Release terminal"
      String.starts_with?(type, "terminal_create_") -> "Create terminal"
      String.starts_with?(type, "terminal_wait_") -> "Wait for terminal"
      String.starts_with?(type, "terminal_output_") -> "Read terminal output"
      String.starts_with?(type, "terminal_release_") -> "Release terminal"
      String.starts_with?(type, "terminal_kill_") -> "Kill terminal"
      true -> String.replace(type, "_", " ")
    end
  end

  defp client_event_tag(type) do
    cond do
      String.starts_with?(type, "file_") -> "File"
      String.starts_with?(type, "terminal_") -> "Terminal"
      true -> "Client"
    end
  end

  defp client_event_status(type) do
    cond do
      String.ends_with?(type, "_requested") -> "Requested"
      String.ends_with?(type, "_succeeded") -> "Succeeded"
      String.ends_with?(type, "_failed") -> "Failed"
      String.ends_with?(type, "_denied") -> "Denied"
      String.ends_with?(type, "_created") -> "Created"
      String.ends_with?(type, "_released") -> "Released"
      true -> "Recorded"
    end
  end

  defp client_event_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        status when status in ["Succeeded", "Created", "Released"] ->
          "border-emerald-200 bg-emerald-50 text-emerald-700"

        status when status in ["Failed", "Denied"] ->
          "border-rose-200 bg-rose-50 text-rose-700"

        "Requested" ->
          "border-amber-200 bg-amber-50 text-amber-700"

        _ ->
          "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp runtime_failure_title("agent_start_failed"), do: "Agent start failed"
  defp runtime_failure_title("agent_protocol_failed"), do: "Agent protocol failed"
  defp runtime_failure_title("agent_process_down"), do: "Agent process disconnected"
  defp runtime_failure_title(_type), do: "Runtime failure"

  defp runtime_failure_reason(%{"reason" => reason}) when reason not in [nil, ""] do
    format_client_value(reason)
  end

  defp runtime_failure_reason(%{"error" => error}) when error not in [nil, ""] do
    format_client_value(error)
  end

  defp runtime_failure_reason(_payload), do: "unknown runtime failure"

  defp runtime_failure_fields(type, payload) do
    [
      client_field("type", "Event", type),
      client_field("agent", "Agent", payload["agent"]),
      client_field("workspace", "Workspace", payload["workspace"]),
      client_field("executable", "Executable", payload["executable"]),
      client_field("cwd", "Working directory", payload["cwd"]),
      client_field("pid", "Process id", payload["pid"]),
      client_field("exit-status", "Exit status", payload["exit_status"]),
      client_field("line", "Line", payload["line"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp client_event_fields(type, payload) do
    [
      client_field("path", "Path", payload["path"]),
      client_field("resolved-path", "Resolved path", payload["resolved_path"]),
      client_field("command", "Command", payload["command"]),
      client_field("args", "Arguments", payload["args"]),
      client_field("cwd", "Working directory", payload["cwd"]),
      client_field("terminal-id", "Terminal id", payload["terminal_id"]),
      client_field("bytes", "Bytes", payload["bytes"]),
      client_field("exit-status", "Exit status", payload["exit_status"]),
      client_field("line", "Line", payload["line"]),
      client_field("limit", "Limit", payload["limit"])
    ]
    |> Enum.reject(&is_nil/1)
    |> then(fn fields ->
      if fields == [] and client_event_error(payload) == nil do
        [client_field("type", "Event", type)]
      else
        fields
      end
    end)
  end

  defp client_field(_id, _label, nil), do: nil
  defp client_field(_id, _label, ""), do: nil

  defp client_field(id, label, value),
    do: %{id: id, label: label, value: format_client_value(value)}

  defp format_client_value(value) when is_list(value), do: Enum.join(value, " ")
  defp format_client_value(value), do: to_string(value)

  defp workspace_name(nil), do: "No workspace"
  defp workspace_name(""), do: "No workspace"

  defp workspace_name(path) do
    case Path.basename(path) do
      "" -> path
      "/" -> path
      name -> name
    end
  end

  defp workspace_name(_path, %{saved?: true, name: name}) when is_binary(name), do: name
  defp workspace_name(path, _workspace_summary), do: workspace_name(path)

  defp workspace_parent(nil), do: nil
  defp workspace_parent(""), do: nil

  defp workspace_parent(path) do
    parent = Path.dirname(path)

    if parent == path do
      nil
    else
      parent
    end
  end

  defp workspace_summary(nil), do: nil
  defp workspace_summary(""), do: nil

  defp workspace_summary(path) do
    case Workspaces.get_workspace_by_path(path) do
      nil ->
        %{
          name: nil,
          path: Path.expand(path),
          path_state: workspace_path_state(path),
          saved?: false
        }

      workspace ->
        %{
          id: workspace.id,
          name: workspace.name,
          path: workspace.path,
          path_state: workspace_path_state(workspace.path),
          saved?: true
        }
    end
  end

  defp workspace_path_state(path) do
    if File.dir?(path), do: :ready, else: :missing
  end

  defp workspace_saved?(%{saved?: true}), do: true
  defp workspace_saved?(_workspace_summary), do: false

  defp workspace_missing?(%{path_state: :missing}), do: true
  defp workspace_missing?(_workspace_summary), do: false

  defp workspace_identity_label(%{saved?: true, name: name}) when is_binary(name), do: name
  defp workspace_identity_label(_workspace_summary), do: "Manual path"

  defp workspace_state_label(nil), do: "Manual path"
  defp workspace_state_label(%{path_state: :ready}), do: "Ready"
  defp workspace_state_label(%{path_state: :missing}), do: "Missing"

  defp workspace_state_class(%{path_state: :ready}) do
    badge_class("border-emerald-200 bg-emerald-50 text-emerald-700")
  end

  defp workspace_state_class(%{path_state: :missing}) do
    badge_class("border-amber-200 bg-amber-50 text-amber-700")
  end

  defp workspace_state_class(nil) do
    badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")
  end

  defp short_session_id(nil), do: "starting"
  defp short_session_id(""), do: "starting"

  defp short_session_id(session_id) when is_binary(session_id) do
    if String.length(session_id) > 12 do
      String.slice(session_id, 0, 8)
    else
      session_id
    end
  end

  defp compact_time_label(nil), do: "unknown"
  defp compact_time_label(time), do: Calendar.strftime(time, "%H:%M:%S")

  defp agent_readiness(agent, workspace) do
    workspace
    |> AgentProbe.agent_inventory(include_preflight: false)
    |> Enum.find(&(&1.agent == agent))
    |> case do
      nil -> %{}
      readiness -> readiness
    end
  end

  defp agent_evidence_label(_inventory, reports) when reports != [] do
    pluralize_count(length(reports), "accepted probe")
  end

  defp agent_evidence_label(%{real_agent_candidate: true}, _reports), do: "Static candidate"
  defp agent_evidence_label(%{status: "invalid"}, _reports), do: "Invalid command"
  defp agent_evidence_label(_inventory, _reports), do: "Local harness"

  defp agent_evidence_class(_inventory, reports) when reports != [] do
    badge_class("border-emerald-200 bg-emerald-50 text-emerald-700")
  end

  defp agent_evidence_class(%{real_agent_candidate: true}, _reports) do
    badge_class("border-sky-200 bg-sky-50 text-sky-700")
  end

  defp agent_evidence_class(%{status: "invalid"}, _reports) do
    badge_class("border-rose-200 bg-rose-50 text-rose-700")
  end

  defp agent_evidence_class(_inventory, _reports) do
    badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")
  end

  defp agent_evidence_reason(_inventory, reports) when reports != [] do
    "validated committed reports prove accepted real-agent evidence"
  end

  defp agent_evidence_reason(%{real_agent_rejection_reasons: []}, _reports) do
    "command resolves; not ACP evidence until preflight or a generated probe passes"
  end

  defp agent_evidence_reason(%{real_agent_rejection_reasons: reasons}, _reports)
       when is_list(reasons),
       do: Enum.join(reasons, "; ")

  defp agent_evidence_reason(_inventory, _reports), do: "agent readiness unknown"

  defp agent_probe_report_label(report) do
    report.path
    |> Path.relative_to(File.cwd!())
    |> then(fn path ->
      "#{path} · #{pluralize_count(length(report.expected_events), "event")} · #{pluralize_count(length(report.expected_event_fields), "field")}"
    end)
  end

  defp capability_gap_class do
    badge_class("border-amber-200 bg-amber-50 text-amber-800")
  end

  defp capability_gap_reason([]), do: nil

  defp capability_gap_reason(reports) do
    "real-agent probes observed generic ACP tool calls, not Haven-mediated #{capability_gap_family_label(reports)} handling"
  end

  defp capability_gap_family_label(reports) do
    reports
    |> capability_gap_families()
    |> case do
      [] -> "capability"
      families -> Enum.join(families, "/")
    end
  end

  defp capability_gap_family_items(reports) do
    capability_gap_families(reports)
  end

  defp capability_gap_families(reports) do
    exact_families =
      reports
      |> Enum.flat_map(&Map.get(&1, :unsupported_client_capabilities, []))
      |> Enum.map(fn
        %{capability: capability} -> capability
        %{"capability" => capability} -> capability
        _capability -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    if exact_families == [] do
      reports
      |> Enum.flat_map(& &1.missing_expected_events)
      |> Enum.filter(&client_capability_event?/1)
      |> Enum.map(fn
        "file_read" <> _rest -> "fs/read_text_file"
        "file_write" <> _rest -> "fs/write_text_file"
        "file_" <> _rest -> "fs"
        "terminal_" <> _rest -> "terminal"
        _event -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      exact_families
    end
  end

  defp capability_gap_report_label(report) do
    capability_label =
      report
      |> List.wrap()
      |> capability_gap_family_label()

    report.path
    |> Path.relative_to(File.cwd!())
    |> then(fn path ->
      "#{path} · #{capability_label} · missing #{Enum.join(report.missing_expected_events, ", ")}"
    end)
  end

  defp client_capability_event?(type) when is_binary(type) do
    String.starts_with?(type, "file_") or String.starts_with?(type, "terminal_")
  end

  defp client_capability_event?(_type), do: false

  defp agent_launch_label(%{status: "ready"}), do: "Launch ready"
  defp agent_launch_label(%{status: "invalid"}), do: "Launch blocked"
  defp agent_launch_label(_inventory), do: "Launch unknown"

  defp agent_launch_class(%{status: "ready"}) do
    badge_class("border-emerald-200 bg-emerald-50 text-emerald-700")
  end

  defp agent_launch_class(%{status: "invalid"}) do
    badge_class("border-rose-200 bg-rose-50 text-rose-700")
  end

  defp agent_launch_class(_inventory) do
    badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")
  end

  defp agent_launch_cwd_scope_label(%{cwd: cwd}) when is_binary(cwd), do: "cwd #{cwd}"
  defp agent_launch_cwd_scope_label(%{status: "ready"}), do: "cwd app default"
  defp agent_launch_cwd_scope_label(_readiness), do: "cwd unknown"

  defp agent_launch_env_scope_label(%{env_keys: keys}) when is_list(keys) do
    keys =
      keys
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    case keys do
      [] -> "env none"
      keys -> "env keys #{Enum.join(keys, ", ")}"
    end
  end

  defp agent_launch_env_scope_label(_readiness), do: "env unknown"

  defp agent_launch_env_auth_label(%{env_keys: keys}) when is_list(keys) do
    keys = normalize_env_keys(keys)

    cond do
      keys == [] -> "No auth env"
      Enum.any?(keys, &credential_env_key?/1) -> "Credential env"
      true -> "Plain env"
    end
  end

  defp agent_launch_env_auth_label(_readiness), do: "Auth unknown"

  defp agent_launch_env_auth_class(%{env_keys: keys}) when is_list(keys) do
    keys = normalize_env_keys(keys)

    cond do
      keys == [] ->
        badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")

      Enum.any?(keys, &credential_env_key?/1) ->
        badge_class("border-amber-200 bg-amber-50 text-amber-700")

      true ->
        badge_class("border-sky-200 bg-sky-50 text-sky-700")
    end
  end

  defp agent_launch_env_auth_class(_readiness),
    do: badge_class("border-zinc-200 bg-zinc-50 text-zinc-600")

  defp agent_launch_env_auth_reason(%{env_keys: keys}) when is_list(keys) do
    keys = normalize_env_keys(keys)
    credential_keys = Enum.filter(keys, &credential_env_key?/1)

    cond do
      keys == [] ->
        "No environment variables were configured for this agent launch."

      credential_keys != [] ->
        "Credential-like keys are available to the agent: #{Enum.join(credential_keys, ", ")}. Values stay hidden in run detail and evidence."

      true ->
        "Environment variable names are available to the agent; values stay hidden in run detail and evidence."
    end
  end

  defp agent_launch_env_auth_reason(_readiness), do: "Agent auth scope is unknown."

  defp normalize_env_keys(keys), do: keys |> Enum.map(&to_string/1) |> Enum.sort()

  defp credential_env_key?(key) do
    key = key |> to_string() |> String.upcase()

    String.contains?(key, "TOKEN") or String.contains?(key, "SECRET") or
      String.contains?(key, "KEY") or String.contains?(key, "PASSWORD") or
      String.contains?(key, "CREDENTIAL")
  end

  defp badge_class(extra_class) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      extra_class
    ]
  end

  defp pluralize_count(1, singular), do: "1 #{singular}"
  defp pluralize_count(count, "recovery"), do: "#{count} recoveries"
  defp pluralize_count(count, singular), do: "#{count} #{singular}s"

  defp client_event_error(payload) do
    case payload["error"] do
      %{"message" => message, "data" => %{"reason" => reason}} ->
        "#{message} (#{reason})"

      %{"message" => message} ->
        message

      _ ->
        nil
    end
  end

  defp tool_call_kind_label("read"), do: "File read"
  defp tool_call_kind_label("execute"), do: "Terminal"
  defp tool_call_kind_label(kind), do: String.replace(to_string(kind), "_", " ")

  defp tool_result_label("completed", 0), do: "Completed successfully"

  defp tool_result_label("completed", exit_code) when is_integer(exit_code),
    do: "Completed with exit #{exit_code}"

  defp tool_result_label(status, _exit_code) when is_binary(status), do: String.capitalize(status)
  defp tool_result_label(_status, _exit_code), do: "Tool result"

  defp tool_call_path(%{"locations" => [%{"path" => path} | _rest]}) when is_binary(path),
    do: path

  defp tool_call_path(_payload), do: nil

  defp tool_call_exit_code(payload) do
    get_in(payload, ["rawOutput", "exit_code"]) ||
      get_in(payload, ["_meta", "terminal_exit", "exit_code"])
  end

  defp tool_call_output(payload) do
    output =
      get_in(payload, ["rawOutput", "formatted_output"]) ||
        get_in(payload, ["_meta", "terminal_output_delta", "data"])

    if is_binary(output) and output != "" do
      String.slice(output, 0, 4_000)
    end
  end

  defp tool_call_id(payload) do
    payload["toolCallId"] || payload["tool_call_id"] || payload["id"]
  end

  defp permission_tool_call_id(permission) do
    tool_call = permission.payload["toolCall"] || %{}
    tool_call["toolCallId"] || tool_call["tool_call_id"] || tool_call["id"] || "unknown"
  end

  defp permission_tool_status(permission) do
    get_in(permission.payload, ["toolCall", "status"]) || "pending"
  end

  defp permission_options(permission) do
    case permission.payload["options"] do
      options when is_list(options) ->
        Enum.filter(options, &(is_map(&1) and is_binary(&1["optionId"])))

      _options ->
        []
    end
  end

  defp permission_options_summary(permission) do
    case permission_options(permission) do
      [] -> "none"
      options -> Enum.map_join(options, ", ", &permission_option_label/1)
    end
  end

  defp permission_option_label(option) do
    "#{option["name"] || "Unnamed option"} (#{option["optionId"]})"
  end

  defp permission_option_title(option, decision_summary) do
    label = permission_option_label(option)
    kind = option["kind"] || option["optionId"] || ""

    cond do
      String.starts_with?(to_string(kind), "allow") ->
        "#{label}: #{decision_summary.consequence}"

      String.starts_with?(to_string(kind), "reject") or
          String.starts_with?(to_string(kind), "deny") ->
        "#{label}: block this request and return the denial to the agent."

      String.starts_with?(to_string(kind), "cancel") ->
        "#{label}: cancel this request and unblock the run."

      true ->
        "#{label}: choose this option for the pending agent request."
    end
  end

  defp permission_decision_summary(permission) do
    raw_input = get_in(permission.payload, ["toolCall", "rawInput"]) || %{}
    title = get_in(permission.payload, ["toolCall", "title"]) || ""

    cond do
      raw_input["content_preview"] || raw_input["diff_preview"] ->
        %{
          action: "Review the proposed file change.",
          consequence: "Allow writes this content to the workspace; deny leaves files unchanged."
        }

      raw_input["command"] && is_nil(raw_input["content_preview"]) &&
          is_nil(raw_input["diff_preview"]) ->
        %{
          action: "Review the terminal command.",
          consequence:
            "Allow starts this process in the workspace; deny prevents it from running."
        }

      String.downcase(title) =~ "read file" ->
        %{
          action: "Review the requested file read.",
          consequence: "Allow sends the file contents to the agent; deny keeps them unavailable."
        }

      String.downcase(title) =~ "write file" ->
        %{
          action: "Review the requested file write.",
          consequence: "Allow lets the agent proceed with this write request; deny blocks it."
        }

      true ->
        %{
          action: "Review the requested agent action.",
          consequence: "Allow returns approval to the agent; deny blocks this action."
        }
    end
  end

  defp event_sequence_label(event, %{seq: result_seq}), do: "##{event.seq}-#{result_seq}"
  defp event_sequence_label(event, _result_event), do: "##{event.seq}"

  defp event_type_label(%{type: "tool_call"}, %{type: "tool_call_update"}),
    do: "tool_call + tool_call_update"

  defp event_type_label(event, _result_event), do: event.type

  defp event_card_class(kind) do
    [
      "rounded-2xl px-4 py-3 text-sm",
      case kind do
        "user" -> "ml-auto max-w-[88%] border border-zinc-200 bg-zinc-50"
        "agent" -> "mr-auto max-w-[88%] border border-zinc-200 bg-white"
        "client" -> "w-full border border-zinc-200 bg-white"
        "protocol" -> "w-full border border-zinc-200 bg-zinc-50"
        "runtime" -> "w-full border border-zinc-200 bg-zinc-50"
        _ -> "w-full border border-zinc-200 bg-white"
      end
    ]
  end

  defp event_kind_class(kind) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case kind do
        "user" -> "border-indigo-200 bg-indigo-50 text-indigo-700"
        "agent" -> "border-sky-200 bg-sky-50 text-sky-700"
        "client" -> "border-amber-200 bg-amber-50 text-amber-700"
        "protocol" -> "border-violet-200 bg-violet-50 text-violet-700"
        "runtime" -> "border-rose-200 bg-rose-50 text-rose-700"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp policy_label("allow"), do: "Allow"
  defp policy_label("deny"), do: "Deny"
  defp policy_label(_ask), do: "Ask"

  defp policy_scope_items(scopes) when is_list(scopes) and scopes != [], do: scopes
  defp policy_scope_items(_scopes), do: ["All workspace paths"]

  defp policy_scope_class(scopes) when is_list(scopes) and scopes != [] do
    "inline-flex max-w-full items-center rounded-md border border-zinc-200 bg-white px-2 py-0.5 text-[11px] font-medium text-zinc-700"
  end

  defp policy_scope_class(_scopes) do
    "inline-flex max-w-full items-center rounded-md border border-amber-200 bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-700"
  end

  defp policy_scope_id(scope) do
    scope
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "scope"
      id -> id
    end
  end

  defp policy_badge_class(decision) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case decision do
        "allow" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "deny" -> "border-rose-200 bg-rose-50 text-rose-700"
        _ask -> "border-amber-200 bg-amber-50 text-amber-700"
      end
    ]
  end

  defp permission_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        "pending" -> "border-amber-200 bg-amber-50 text-amber-700"
        "resolved" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "cancelled" -> "border-zinc-200 bg-zinc-50 text-zinc-600"
        "ignored" -> "border-violet-200 bg-violet-50 text-violet-700"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp permission_kind_label("agent_permission"), do: "Agent permission"
  defp permission_kind_label("file_read"), do: "File read"
  defp permission_kind_label("file_write"), do: "File write"
  defp permission_kind_label("terminal_create"), do: "Terminal create"
  defp permission_kind_label("resolution_attempt"), do: "Stale resolution"
  defp permission_kind_label(kind), do: kind || "Permission"

  defp permission_options_label(%{"items" => options}) when is_list(options) do
    options
    |> Enum.map(&(&1["optionId"] || &1["name"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      label -> label
    end
  end

  defp permission_options_label(_options), do: "none"

  defp audit_time_label(nil), do: "unknown"

  defp audit_time_label(%DateTime{} = time) do
    Calendar.strftime(time, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp permission_audit_for_event(audits, event) do
    request_id = to_string(event.payload["request_id"])

    Enum.find(audits, fn audit ->
      to_string(audit.request_id) == request_id
    end)
  end

  defp permission_request_event_for_audit(events, audit) do
    Enum.find(events, fn event ->
      event.type == "permission_requested" and same_request_id?(event, audit)
    end)
  end

  defp permission_resolution_event_for_audit(events, audit) do
    resolution_type =
      if audit.status == "ignored" do
        "permission_resolution_ignored"
      else
        "permission_resolved"
      end

    Enum.find(events, fn event ->
      event.type == resolution_type and same_request_id?(event, audit)
    end)
  end

  defp same_request_id?(event, audit) do
    to_string(event.payload["request_id"]) == to_string(audit.request_id)
  end

  defp permission_resolution_title(
         %{type: "permission_resolution_ignored", payload: payload},
         _audit
       ) do
    "Stale decision ignored: #{payload["option_id"] || "unknown"}"
  end

  defp permission_resolution_title(%{payload: payload}, audit) do
    title =
      if audit do
        audit.title || permission_kind_label(audit.kind)
      else
        "permission request"
      end

    "Decision recorded: #{payload["option_id"] || "unknown"} for #{title}"
  end

  defp permission_resolution_status(%{type: "permission_resolution_ignored"}, _audit),
    do: "ignored"

  defp permission_resolution_status(_event, %{status: status}), do: status

  defp permission_resolution_status(%{payload: %{"outcome" => "cancelled"}}, _audit),
    do: "cancelled"

  defp permission_resolution_status(_event, _audit), do: "resolved"

  defp permission_resolution_fields(event, audit) do
    payload = event.payload

    [
      %{id: "request", label: "Request", value: payload["request_id"]},
      %{id: "selected", label: "Selected", value: payload["option_id"]},
      audit && %{id: "kind", label: "Kind", value: permission_kind_label(audit.kind)},
      audit && audit.tool_call_id &&
        %{id: "tool-call", label: "Tool call", value: audit.tool_call_id},
      %{id: "actor", label: "Actor", value: payload["actor"]},
      %{id: "outcome", label: "Outcome", value: payload["outcome"]},
      %{id: "reason", label: "Reason", value: payload["reason"]}
    ]
    |> Enum.reject(fn
      nil -> true
      %{value: nil} -> true
      %{value: ""} -> true
      _field -> false
    end)
  end

  defp terminal_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        "running" -> "border-sky-200 bg-sky-50 text-sky-700"
        "exited" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "killed" -> "border-rose-200 bg-rose-50 text-rose-700"
        "failed" -> "border-rose-200 bg-rose-50 text-rose-700"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp terminal_session_counts(sessions) do
    counts = Enum.frequencies_by(sessions, & &1.status)

    %{
      "all" => length(sessions),
      "running" => Map.get(counts, "running", 0),
      "completed" => Map.get(counts, "exited", 0) + Map.get(counts, "released", 0),
      "attention" => Map.get(counts, "killed", 0) + Map.get(counts, "failed", 0)
    }
  end

  defp terminal_session_summary_label(%{"all" => 0}), do: "None"

  defp terminal_session_summary_label(counts) do
    [
      summary_count(Map.get(counts, "running", 0), "running"),
      summary_count(Map.get(counts, "completed", 0), "completed"),
      summary_count(Map.get(counts, "attention", 0), "attention")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp terminal_review_label(%{status: "running"}), do: "Running"

  defp terminal_review_label(%{status: status}) when status in ["exited", "released"],
    do: "Completed"

  defp terminal_review_label(%{status: status}) when status in ["killed", "failed"],
    do: "Needs attention"

  defp terminal_review_label(_session), do: "Recorded"

  defp summary_count(0, _label), do: nil
  defp summary_count(count, label), do: "#{count} #{label}"

  defp terminal_review_hint(%{status: "running"}) do
    "This terminal is still active or waiting for output."
  end

  defp terminal_review_hint(%{status: "exited", exit_status: 0}) do
    "The command exited successfully."
  end

  defp terminal_review_hint(%{status: "exited", exit_status: status}) when not is_nil(status) do
    "The command exited with status #{status}."
  end

  defp terminal_review_hint(%{status: "released"}) do
    "The terminal was released without a captured exit status."
  end

  defp terminal_review_hint(%{status: "killed"}) do
    "The terminal was killed before normal completion."
  end

  defp terminal_review_hint(%{status: "failed"}) do
    "Terminal execution failed; inspect the timeline for the failure event."
  end

  defp terminal_review_hint(_session), do: "This terminal session is recorded for review."

  defp terminal_args_label(%{"items" => []}), do: "none"
  defp terminal_args_label(%{"items" => args}) when is_list(args), do: Enum.join(args, " ")
  defp terminal_args_label(_args), do: "none"

  defp terminal_env_keys_label(%{"items" => []}), do: "none"
  defp terminal_env_keys_label(%{"items" => keys}) when is_list(keys), do: Enum.join(keys, ", ")
  defp terminal_env_keys_label(_keys), do: "none"

  defp terminal_exit_label(nil), do: "running"
  defp terminal_exit_label(status), do: to_string(status)

  defp terminal_output_preview(""), do: nil
  defp terminal_output_preview(nil), do: nil
  defp terminal_output_preview(preview), do: preview

  defp file_change_status_class(status) do
    [
      "inline-flex rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase",
      case status do
        "pending" -> "border-amber-200 bg-amber-50 text-amber-700"
        "applied" -> "border-emerald-200 bg-emerald-50 text-emerald-700"
        "denied" -> "border-rose-200 bg-rose-50 text-rose-700"
        "failed" -> "border-rose-200 bg-rose-50 text-rose-700"
        "cancelled" -> "border-zinc-200 bg-zinc-50 text-zinc-600"
        _ -> "border-zinc-200 bg-zinc-50 text-zinc-600"
      end
    ]
  end

  defp file_change_counts(changes) do
    counts = Enum.frequencies_by(changes, & &1.status)

    %{
      "all" => length(changes),
      "pending" => Map.get(counts, "pending", 0),
      "applied" => Map.get(counts, "applied", 0),
      "blocked" =>
        Enum.reduce(["denied", "failed", "cancelled"], 0, fn status, total ->
          total + Map.get(counts, status, 0)
        end)
    }
  end

  defp file_change_summary_label(%{"all" => 0}), do: "None"

  defp file_change_summary_label(counts) do
    [
      summary_count(Map.get(counts, "pending", 0), "pending"),
      summary_count(Map.get(counts, "applied", 0), "applied"),
      summary_count(Map.get(counts, "blocked", 0), "blocked")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp file_change_review_label(%{status: "pending"}), do: "Needs review"
  defp file_change_review_label(%{status: "applied"}), do: "Applied"

  defp file_change_review_label(%{status: status})
       when status in ["denied", "failed", "cancelled"],
       do: "Blocked"

  defp file_change_review_label(_change), do: "Recorded"

  defp file_change_review_hint(%{status: "pending"}) do
    "Review the proposed content and diff before deciding."
  end

  defp file_change_review_hint(%{status: "applied"}) do
    "This change was written to the workspace."
  end

  defp file_change_review_hint(%{status: "denied"}) do
    "This proposed change was denied and did not touch the workspace."
  end

  defp file_change_review_hint(%{status: "failed"}) do
    "This proposed change failed while applying."
  end

  defp file_change_review_hint(%{status: "cancelled"}) do
    "This proposed change was cancelled before completion."
  end

  defp file_change_review_hint(_change), do: "This file change is recorded for review."

  defp file_change_error(nil), do: nil

  defp file_change_error(%{"message" => message, "data" => %{"reason" => reason}}) do
    "#{message} (#{reason})"
  end

  defp file_change_error(%{"message" => message}), do: message
  defp file_change_error(_error), do: "File change failed"

  defp file_change_preview(""), do: nil
  defp file_change_preview(nil), do: nil
  defp file_change_preview(preview), do: preview

  defp proposed_file_change(%{payload: payload}) do
    raw_input = get_in(payload, ["toolCall", "rawInput"]) || %{}

    if raw_input["content_preview"] || raw_input["diff_preview"] do
      raw_input
    end
  end

  defp proposed_file_change(_permission), do: nil

  defp proposed_terminal_request(%{payload: payload}) do
    raw_input = get_in(payload, ["toolCall", "rawInput"]) || %{}

    if raw_input["command"] && is_nil(raw_input["content_preview"]) &&
         is_nil(raw_input["diff_preview"]) do
      raw_input
    end
  end

  defp proposed_terminal_request(_permission), do: nil

  defp terminal_request_args_label(args) when is_list(args) and args != [],
    do: Enum.join(args, " ")

  defp terminal_request_args_label(_args), do: "none"

  defp terminal_request_env_keys(nil), do: "none"
  defp terminal_request_env_keys(env) when env == %{}, do: "none"

  defp terminal_request_env_keys(env) when is_map(env) do
    env
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp terminal_request_env_keys(_env), do: "none"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="haven-run" class="min-h-dvh bg-white text-zinc-950">
        <section class="mx-auto grid max-w-6xl gap-4 px-4 py-4 md:px-8 md:py-6 lg:grid-cols-[minmax(0,1fr)_320px]">
          <div class="min-w-0 space-y-4">
            <header class="border-b border-zinc-200 pb-4">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <.link
                    id="run-header-inbox-link"
                    navigate={~p"/"}
                    class="inline-flex h-9 items-center gap-2 rounded-md border border-zinc-200 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 hover:text-zinc-950"
                  >
                    <.icon name="hero-arrow-left" class="size-4" />
                    <span>Inbox</span>
                    <span
                      :if={inbox_attention_badge(@inbox_attention_summary)}
                      id="run-header-inbox-attention"
                      title={inbox_attention_title(@inbox_attention_summary)}
                      aria-label={inbox_attention_title(@inbox_attention_summary)}
                      class="rounded-full border border-sky-200 bg-sky-50 px-2 py-0.5 text-[11px] font-semibold uppercase text-sky-700"
                    >
                      {inbox_attention_badge(@inbox_attention_summary)}
                    </span>
                  </.link>
                  <h1 class="mt-2 truncate text-2xl font-semibold">{@run.title}</h1>
                  <p
                    id="run-header-workspace"
                    title={@run.workspace}
                    class="mt-1 flex min-w-0 items-center gap-1 truncate text-sm text-zinc-500"
                  >
                    <.icon name="hero-folder" class="size-4 shrink-0 text-zinc-400" />
                    <span class="truncate font-medium text-zinc-700">
                      {workspace_name(@run.workspace, @workspace_summary)}
                    </span>
                    <span
                      id="run-header-workspace-state"
                      class={["ml-1 shrink-0", workspace_state_class(@workspace_summary)]}
                    >
                      {workspace_state_label(@workspace_summary)}
                    </span>
                  </p>
                  <p
                    :if={workspace_parent(@run.workspace)}
                    id="run-header-workspace-path"
                    class="mt-0.5 truncate text-xs text-zinc-500"
                  >
                    {workspace_parent(@run.workspace)}
                  </p>
                  <p
                    :if={workspace_saved?(@workspace_summary)}
                    id="run-header-workspace-saved-path"
                    class="mt-0.5 truncate text-xs text-zinc-500"
                  >
                    {@workspace_summary.path}
                  </p>
                  <dl
                    id="run-header-identity"
                    class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500"
                  >
                    <div id="run-header-agent" class="inline-flex min-w-0 items-center gap-1">
                      <dt class="font-semibold text-zinc-600">Agent</dt>
                      <dd class="truncate font-mono text-zinc-800">{@run.agent}</dd>
                    </div>
                    <div
                      id="run-header-session"
                      title={@run.agent_session_id || "starting"}
                      class="inline-flex min-w-0 items-center gap-1"
                    >
                      <dt class="font-semibold text-zinc-600">Session</dt>
                      <dd class="truncate font-mono text-zinc-800">
                        {short_session_id(@run.agent_session_id)}
                      </dd>
                    </div>
                    <div id="run-header-updated" class="inline-flex min-w-0 items-center gap-1">
                      <dt class="font-semibold text-zinc-600">Updated</dt>
                      <dd class="font-mono text-zinc-800">{compact_time_label(@run.updated_at)}</dd>
                    </div>
                  </dl>
                </div>
                <div class="flex shrink-0 flex-col items-end gap-2">
                  <span
                    id="run-header-status"
                    title={header_status_title(@run, @live?)}
                    aria-label={header_status_title(@run, @live?)}
                    class={header_status_class(@run, @live?)}
                  >
                    {header_status_label(@run, @live?)}
                  </span>
                  <span
                    :if={@run.archived_at}
                    id="run-header-archive-state"
                    title={"Archived at #{Calendar.strftime(@run.archived_at, "%Y-%m-%d %H:%M:%S")}"}
                    class="inline-flex items-center rounded-full border border-zinc-300 bg-zinc-100 px-3 py-1 text-xs font-semibold uppercase text-zinc-700"
                  >
                    Archived
                  </span>
                </div>
              </div>
            </header>

            <nav
              id="run-section-nav"
              aria-label="Run sections"
              class="sticky top-0 z-10 -mx-4 overflow-x-auto border-b border-zinc-200 bg-white/95 px-4 py-2 backdrop-blur md:static md:mx-0 md:rounded-lg md:border md:p-2 md:shadow-sm md:backdrop-blur-none"
            >
              <div class="flex min-w-max gap-2">
                <a
                  id="run-nav-thread"
                  href="#run-thread"
                  class="inline-flex h-10 items-center gap-2 rounded-md bg-zinc-950 px-3 text-sm font-semibold text-white transition hover:bg-zinc-800"
                >
                  <.icon name="hero-chat-bubble-left-right" class="size-4" />
                  <span>Thread</span>
                  <span
                    id="run-nav-thread-count"
                    class="rounded bg-white/15 px-1.5 py-0.5 text-[11px]"
                  >
                    {@run_nav_counts.thread}
                  </span>
                </a>
                <a
                  id="run-nav-decisions"
                  href={
                    if(@pending_permission,
                      do: "#pending-permission-card",
                      else: "#run-permission-audit"
                    )
                  }
                  class={[
                    "inline-flex h-10 items-center gap-2 rounded-md border px-3 text-sm font-semibold transition",
                    if(@pending_permission,
                      do: "border-amber-300 bg-amber-50 text-amber-950 hover:bg-amber-100",
                      else: "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50"
                    )
                  ]}
                >
                  <.icon name="hero-hand-raised" class="size-4 text-amber-600" />
                  <span>{if @pending_permission, do: "Needs you", else: "Decisions"}</span>
                  <span
                    id="run-nav-decisions-count"
                    class={[
                      "rounded px-1.5 py-0.5 text-[11px]",
                      if(@pending_permission,
                        do: "bg-amber-100 text-amber-900",
                        else: "bg-zinc-100 text-zinc-600"
                      )
                    ]}
                  >
                    {@run_nav_counts.decisions}
                  </span>
                </a>
                <a
                  id="run-nav-message"
                  href="#run-control-panel"
                  class="inline-flex h-10 items-center gap-2 rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                >
                  <.icon name="hero-paper-airplane" class="size-4 text-sky-600" />
                  <span>Message</span>
                </a>
                <a
                  id="run-nav-evidence"
                  href="#run-evidence-summary"
                  class="inline-flex h-10 items-center gap-2 rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                >
                  <.icon name="hero-archive-box" class="size-4 text-zinc-500" />
                  <span>Evidence</span>
                  <span
                    id="run-nav-evidence-count"
                    class="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600"
                  >
                    {@run_nav_counts.evidence}
                  </span>
                </a>
                <a
                  id="run-nav-files"
                  href="#run-file-changes"
                  class="inline-flex h-10 items-center gap-2 rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                >
                  <.icon name="hero-document-text" class="size-4 text-emerald-600" />
                  <span>Files</span>
                  <span
                    id="run-nav-files-count"
                    title={file_change_summary_label(@file_change_counts)}
                    aria-label={"File changes: #{file_change_summary_label(@file_change_counts)}"}
                    class="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600"
                  >
                    {length(@file_changes)}
                  </span>
                </a>
                <a
                  id="run-nav-terminals"
                  href="#run-terminal-sessions"
                  class="inline-flex h-10 items-center gap-2 rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                >
                  <.icon name="hero-command-line" class="size-4 text-zinc-600" />
                  <span>Terminals</span>
                  <span
                    id="run-nav-terminals-count"
                    title={terminal_session_summary_label(@terminal_session_counts)}
                    aria-label={"Terminal sessions: #{terminal_session_summary_label(@terminal_session_counts)}"}
                    class="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600"
                  >
                    {length(@terminal_sessions)}
                  </span>
                </a>
              </div>
            </nav>

            <section id="run-thread" class="flex flex-col gap-3">
              <section
                :if={@run.archived_at}
                id="run-archive-card"
                class="rounded-2xl border border-zinc-200 bg-zinc-50 p-4"
              >
                <p class="text-xs font-semibold uppercase text-zinc-500">Review-only</p>
                <h2 class="mt-1 text-base font-semibold text-zinc-950">Archived history</h2>
                <p class="mt-2 text-sm text-zinc-700">
                  This run was archived at {Calendar.strftime(
                    @run.archived_at,
                    "%Y-%m-%d %H:%M:%S"
                  )}. Its transcript, decisions, files, terminals, and timeline remain inspectable, but no live agent process will be reconnected from this record.
                </p>
              </section>

              <section
                :if={@recovery_attention}
                id="run-recovery-card"
                class="rounded-2xl border border-rose-200 bg-rose-50 p-4"
              >
                <p class="text-xs font-semibold uppercase text-rose-700">Needs recovery</p>
                <h2 class="mt-1 text-base font-semibold text-zinc-950">
                  {@recovery_attention.title}
                </h2>
                <p class="mt-2 text-sm text-zinc-700">
                  {@recovery_attention.body}
                </p>
                <div
                  :if={@latest_failure_summary}
                  id="run-recovery-failure-summary"
                  class="mt-3 rounded-md border border-rose-200 bg-white px-3 py-2 text-sm"
                >
                  <p class="text-xs font-semibold uppercase text-rose-700">Latest failure</p>
                  <p id="run-recovery-failure-title" class="mt-1 font-semibold text-zinc-950">
                    {@latest_failure_summary.title}
                  </p>
                  <p
                    id="run-recovery-failure-reason"
                    class="mt-1 break-words text-rose-800"
                  >
                    {@latest_failure_summary.reason}
                  </p>
                  <a
                    id="run-recovery-failure-event-link"
                    href={"#event-#{@latest_failure_summary.seq}"}
                    class="mt-2 inline-flex items-center gap-1 text-xs font-semibold text-zinc-700 transition hover:text-zinc-950"
                  >
                    <.icon name="hero-arrow-down-circle" class="size-3.5" /> View event
                  </a>
                </div>
                <div
                  :if={@can_retry_last_prompt?}
                  id="retry-last-prompt-preview"
                  class="mt-3 line-clamp-3 rounded-md border border-rose-200 bg-white px-3 py-2 text-sm text-zinc-700"
                >
                  <p class="text-xs font-semibold uppercase text-rose-700">Last prompt</p>
                  <p class="mt-1 whitespace-pre-wrap">{@last_user_prompt}</p>
                </div>
                <ul
                  :if={recovery_option_rows(assigns) != []}
                  id="run-recovery-option-guide"
                  class="mt-3 space-y-2 text-sm text-zinc-700"
                >
                  <li
                    :for={option <- recovery_option_rows(assigns)}
                    id={"run-recovery-option-#{option.id}"}
                    class="grid gap-1 sm:grid-cols-[9rem_minmax(0,1fr)]"
                  >
                    <span class="font-semibold text-zinc-950">{option.label}</span>
                    <span>{option.description}</span>
                  </li>
                </ul>
                <.form
                  :if={@can_continue_failed?}
                  id="continue-after-failure-form"
                  for={to_form(%{})}
                  phx-submit="continue_failed"
                  class="mt-3 space-y-2"
                >
                  <textarea
                    id="continue-after-failure-prompt"
                    name="prompt"
                    class="min-h-24 w-full rounded-md border border-rose-200 bg-white px-3 py-2 text-sm shadow-sm outline-none transition placeholder:text-zinc-400 focus:border-rose-700 focus:ring-2 focus:ring-rose-700/10"
                    placeholder="Continue with a new instruction"
                  ></textarea>
                  <button
                    id="continue-after-failure-button"
                    class="h-10 w-full rounded-md bg-rose-700 px-4 text-sm font-semibold text-white transition hover:bg-rose-800 sm:w-auto"
                  >
                    Continue with new prompt
                  </button>
                </.form>
                <div class="mt-3 flex flex-wrap gap-2">
                  <button
                    :if={@can_retry_last_prompt?}
                    id="retry-last-prompt-button"
                    type="button"
                    title="Restart this run and resend the last user prompt."
                    class="h-10 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800"
                    phx-click="retry_last_prompt"
                  >
                    Retry last prompt
                  </button>
                  <button
                    :if={@recovery_attention.action}
                    id="run-recovery-action-button"
                    type="button"
                    title={recovery_action_title(@recovery_attention.action)}
                    class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                    phx-click="reconnect"
                  >
                    {@recovery_attention.action}
                  </button>
                </div>
              </section>

              <section
                :if={@pending_permission}
                id="pending-permission-card"
                class="rounded-2xl border border-zinc-300 bg-white p-4"
              >
                <% decision_summary = permission_decision_summary(@pending_permission) %>
                <p class="text-xs font-semibold uppercase text-zinc-500">Needs approval</p>
                <h2 class="mt-1 text-base font-semibold text-zinc-950">
                  {get_in(@pending_permission.payload, ["toolCall", "title"]) || "Approve request?"}
                </h2>
                <p class="mt-2 text-sm text-zinc-600">
                  The agent is blocked until you choose an option.
                </p>
                <div
                  :if={!@live?}
                  id="pending-permission-stale-notice"
                  class="mt-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800"
                >
                  This saved decision is no longer attached to a live agent process. Reconnect will
                  cancel the stale request, start a fresh ACP session, and keep this record in the
                  permission audit.
                </div>
                <div
                  :if={@last_user_prompt}
                  id="pending-permission-conversation-context"
                  class="mt-3 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-700"
                >
                  <p class="text-xs font-semibold uppercase text-zinc-500">Prompt context</p>
                  <p class="mt-1 line-clamp-3 whitespace-pre-wrap">{@last_user_prompt}</p>
                </div>
                <div
                  id="pending-permission-decision-summary"
                  class="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"
                >
                  <p id="pending-permission-decision-action" class="font-semibold">
                    {decision_summary.action}
                  </p>
                  <p id="pending-permission-decision-consequence" class="mt-1 text-amber-900">
                    {decision_summary.consequence}
                  </p>
                </div>
                <a
                  id="pending-permission-event-link"
                  href="#run-activity-timeline"
                  class="mt-3 inline-flex items-center gap-1 text-sm font-semibold text-zinc-700 transition hover:text-zinc-950"
                >
                  <.icon name="hero-arrow-down-circle" class="size-4" /> Open activity timeline
                  <span
                    id="pending-permission-event-reference"
                    class="font-mono text-xs font-medium text-zinc-500"
                  >
                    #event-{@pending_permission.seq}
                  </span>
                </a>
                <% proposed_change = proposed_file_change(@pending_permission) %>
                <section
                  :if={proposed_change}
                  id="pending-permission-proposed-file-change"
                  class="mt-3 rounded-lg border border-zinc-200 bg-white p-3"
                >
                  <div class="flex min-w-0 items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="text-xs font-semibold uppercase text-zinc-500">
                        Proposed file change
                      </p>
                      <p
                        id="pending-permission-proposed-file-path"
                        class="mt-1 truncate font-mono text-sm font-semibold text-zinc-950"
                      >
                        {proposed_change["path"]}
                      </p>
                    </div>
                    <span
                      id="pending-permission-proposed-file-kind"
                      class="inline-flex shrink-0 rounded-full border border-zinc-200 bg-zinc-50 px-2 py-0.5 text-[11px] font-semibold uppercase text-zinc-600"
                    >
                      {proposed_change["diff_kind"] || "unknown"}
                    </span>
                  </div>
                  <dl class="mt-3 grid gap-2 text-xs text-zinc-700 sm:grid-cols-3">
                    <div id="pending-permission-proposed-file-change-id">
                      <dt class="font-semibold uppercase text-zinc-500">Change</dt>
                      <dd class="break-all font-mono">{proposed_change["change_id"]}</dd>
                    </div>
                    <div id="pending-permission-proposed-file-bytes">
                      <dt class="font-semibold uppercase text-zinc-500">Bytes</dt>
                      <dd class="font-mono">{proposed_change["bytes"]}</dd>
                    </div>
                    <div id="pending-permission-proposed-file-existing-bytes">
                      <dt class="font-semibold uppercase text-zinc-500">Existing bytes</dt>
                      <dd class="font-mono">{proposed_change["existing_bytes"] || 0}</dd>
                    </div>
                  </dl>
                  <pre
                    :if={file_change_preview(proposed_change["content_preview"])}
                    id="pending-permission-proposed-file-content"
                    class="mt-3 max-h-32 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
                  ><%= proposed_change["content_preview"] %></pre>
                  <p
                    :if={proposed_change["content_truncated"]}
                    id="pending-permission-proposed-file-content-truncated"
                    class="mt-2 text-xs font-medium text-amber-700"
                  >
                    Content preview truncated.
                  </p>
                  <pre
                    :if={file_change_preview(proposed_change["diff_preview"])}
                    id="pending-permission-proposed-file-diff"
                    class="mt-3 max-h-40 overflow-auto rounded-md bg-white p-3 text-xs text-zinc-800 ring-1 ring-zinc-200"
                  ><%= proposed_change["diff_preview"] %></pre>
                  <p
                    :if={proposed_change["diff_truncated"]}
                    id="pending-permission-proposed-file-diff-truncated"
                    class="mt-2 text-xs font-medium text-amber-700"
                  >
                    Diff preview truncated.
                  </p>
                </section>
                <% proposed_terminal = proposed_terminal_request(@pending_permission) %>
                <section
                  :if={proposed_terminal}
                  id="pending-permission-proposed-terminal"
                  class="mt-3 rounded-lg border border-zinc-200 bg-white p-3"
                >
                  <p class="text-xs font-semibold uppercase text-zinc-500">
                    Proposed terminal
                  </p>
                  <p
                    id="pending-permission-proposed-terminal-command"
                    class="mt-1 break-all font-mono text-sm font-semibold text-zinc-950"
                  >
                    {proposed_terminal["command"]}
                  </p>
                  <dl class="mt-3 grid gap-2 text-xs text-zinc-700 sm:grid-cols-3">
                    <div id="pending-permission-proposed-terminal-args">
                      <dt class="font-semibold uppercase text-zinc-500">Args</dt>
                      <dd class="break-all font-mono">
                        {terminal_request_args_label(proposed_terminal["args"])}
                      </dd>
                    </div>
                    <div id="pending-permission-proposed-terminal-cwd">
                      <dt class="font-semibold uppercase text-zinc-500">Working directory</dt>
                      <dd class="break-all font-mono">
                        {proposed_terminal["cwd"] || @run.workspace}
                      </dd>
                    </div>
                    <div id="pending-permission-proposed-terminal-env">
                      <dt class="font-semibold uppercase text-zinc-500">Env keys</dt>
                      <dd class="break-all font-mono">
                        {terminal_request_env_keys(proposed_terminal["env"])}
                      </dd>
                    </div>
                  </dl>
                </section>
                <div id="pending-permission-primary-actions" class="mt-3 flex flex-wrap gap-2">
                  <button
                    :for={option <- permission_options(@pending_permission)}
                    class={[
                      "h-10 rounded-md px-4 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-50",
                      if(String.starts_with?(to_string(option["kind"]), "allow"),
                        do: "bg-zinc-950 text-white hover:bg-zinc-800",
                        else: "border border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50"
                      )
                    ]}
                    phx-click="resolve_permission"
                    phx-value-request-id={@pending_permission.payload["request_id"]}
                    phx-value-option-id={option["optionId"]}
                    title={permission_option_title(option, decision_summary)}
                    aria-label={permission_option_title(option, decision_summary)}
                    disabled={!@live?}
                  >
                    {option["name"] || option["optionId"] || "Choose option"}
                  </button>
                  <p
                    :if={permission_options(@pending_permission) == []}
                    id="pending-permission-missing-options"
                    class="w-full rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm font-medium text-rose-700"
                  >
                    This permission request did not include any valid decision options.
                  </p>
                  <button
                    id="pending-permission-cancel-button"
                    type="button"
                    class="h-10 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                    phx-click="cancel"
                    title="Cancel the current turn and resolve outstanding decisions as cancelled."
                    aria-label="Cancel the current turn and resolve outstanding decisions as cancelled."
                    disabled={!@can_cancel?}
                  >
                    Cancel turn
                  </button>
                </div>
                <details
                  id="pending-permission-details"
                  class="mt-3 rounded-md border border-zinc-200 px-3 py-2"
                >
                  <summary class="cursor-pointer text-sm font-medium text-zinc-700">
                    Review details
                  </summary>
                  <dl
                    id="pending-permission-authority"
                    class="mt-3 grid gap-2 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-700 sm:grid-cols-3"
                  >
                    <div id="pending-permission-authority-read" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Reads</dt>
                      <dd class="mt-1 flex flex-wrap items-center gap-1">
                        <span class={policy_badge_class(@capability_policy["file_read"])}>
                          {policy_label(@capability_policy["file_read"])}
                        </span>
                        <span
                          :for={scope <- policy_scope_items(@capability_policy["file_read_paths"])}
                          id={"pending-permission-read-scope-#{policy_scope_id(scope)}"}
                          class={policy_scope_class(@capability_policy["file_read_paths"])}
                        >
                          <span class="truncate">{scope}</span>
                        </span>
                      </dd>
                    </div>
                    <div id="pending-permission-authority-write" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Writes</dt>
                      <dd class="mt-1 flex flex-wrap items-center gap-1">
                        <span class={policy_badge_class(@capability_policy["file_write"])}>
                          {policy_label(@capability_policy["file_write"])}
                        </span>
                        <span
                          :for={scope <- policy_scope_items(@capability_policy["file_write_paths"])}
                          id={"pending-permission-write-scope-#{policy_scope_id(scope)}"}
                          class={policy_scope_class(@capability_policy["file_write_paths"])}
                        >
                          <span class="truncate">{scope}</span>
                        </span>
                      </dd>
                    </div>
                    <div id="pending-permission-authority-terminal" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Terminals</dt>
                      <dd class="mt-1">
                        <span class={policy_badge_class(@capability_policy["terminal_create"])}>
                          {policy_label(@capability_policy["terminal_create"])}
                        </span>
                      </dd>
                    </div>
                  </dl>
                  <dl class="mt-3 grid gap-2 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-700 sm:grid-cols-2">
                    <div id="pending-permission-request-id" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Request</dt>
                      <dd class="truncate font-mono">{@pending_permission.payload["request_id"]}</dd>
                    </div>
                    <div id="pending-permission-tool-call-id" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Tool call</dt>
                      <dd class="truncate font-mono">
                        {permission_tool_call_id(@pending_permission)}
                      </dd>
                    </div>
                    <div id="pending-permission-tool-status" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Status</dt>
                      <dd class="truncate font-mono">
                        {permission_tool_status(@pending_permission)}
                      </dd>
                    </div>
                    <div id="pending-permission-options" class="min-w-0">
                      <dt class="font-semibold uppercase text-zinc-500">Options</dt>
                      <dd class="truncate font-mono">
                        {permission_options_summary(@pending_permission)}
                      </dd>
                    </div>
                  </dl>
                  <pre class="mt-2 max-h-40 overflow-auto rounded-md bg-zinc-50 p-3 text-xs text-zinc-700"><%= Jason.encode!(get_in(@pending_permission.payload, ["toolCall", "rawInput"]) || %{}, pretty: true) %></pre>
                </details>
              </section>

              <section
                :if={@conversation_messages != []}
                id="run-conversation"
                class="space-y-3 rounded-lg border border-zinc-200 bg-zinc-50 p-3"
              >
                <h2 class="px-1 text-xs font-semibold uppercase text-zinc-500">
                  Conversation
                </h2>
                <div class="flex flex-col gap-3">
                  <article
                    :for={message <- @conversation_messages}
                    id={"conversation-message-#{message.seq}"}
                    data-conversation-role={message.role}
                    class={conversation_message_class(message.role)}
                  >
                    <div class="mb-1 flex items-center justify-between gap-3">
                      <span class={[
                        "text-[11px] font-semibold uppercase",
                        conversation_message_label_class(message.role)
                      ]}>
                        {conversation_message_label(message.role)}
                      </span>
                      <span class={[
                        "text-[11px] tabular-nums",
                        conversation_message_label_class(message.role)
                      ]}>
                        {Calendar.strftime(message.inserted_at, "%H:%M:%S")}
                      </span>
                    </div>
                    <p class="whitespace-pre-wrap">{message.text}</p>
                  </article>
                </div>
              </section>

              <section
                :if={
                  @conversation_messages == [] and is_nil(@pending_permission) and
                    is_nil(@recovery_attention) and is_nil(@run.archived_at)
                }
                id="run-thread-empty-state"
                class="rounded-lg border border-dashed border-zinc-300 bg-zinc-50 px-4 py-5 text-center"
              >
                <.icon name="hero-chat-bubble-left-right" class="mx-auto size-6 text-zinc-400" />
                <h2 class="mt-2 text-sm font-semibold text-zinc-950">
                  {if @can_prompt?, do: "Ready for a prompt", else: "No messages yet"}
                </h2>
                <p class="mt-1 text-sm text-zinc-500">
                  {if @can_prompt?,
                    do: "The agent is connected and waiting.",
                    else: "This run has no conversation messages yet."}
                </p>
              </section>

              <section
                id="run-control-panel"
                class={[
                  "bg-white",
                  @can_prompt? &&
                    "sticky bottom-0 z-20 -mx-4 border-y border-zinc-200 bg-white/95 px-4 pb-[calc(0.75rem+env(safe-area-inset-bottom))] pt-3 shadow-[0_-12px_28px_rgba(255,255,255,0.92)] backdrop-blur md:static md:mx-0 md:rounded-lg md:border md:p-4 md:shadow-none md:backdrop-blur-none",
                  !@can_prompt? &&
                    "rounded-lg border border-zinc-200 p-4"
                ]}
              >
                <h2 class="text-sm font-semibold text-zinc-950">Message</h2>
                <div
                  :if={@control_notice}
                  id="run-control-notice"
                  class="mt-2 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-600 sm:flex sm:items-center sm:justify-between sm:gap-3"
                >
                  <p>{@control_notice}</p>
                  <a
                    :if={not is_nil(@pending_permission) and @run.status == "waiting"}
                    id="run-control-review-decision-link"
                    href="#pending-permission-card"
                    class="mt-2 inline-flex h-8 items-center justify-center rounded-md border border-amber-300 bg-amber-50 px-3 font-semibold text-amber-950 transition hover:bg-amber-100 sm:mt-0"
                  >
                    Review decision
                  </a>
                </div>
                <.form
                  id="run-prompt-form"
                  for={to_form(%{})}
                  phx-submit="send_prompt"
                  class="mt-3 space-y-2"
                >
                  <textarea
                    id="run-prompt"
                    name="prompt"
                    rows="2"
                    class="min-h-20 w-full resize-y rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm outline-none transition placeholder:text-zinc-400 focus:border-zinc-900 focus:ring-2 focus:ring-zinc-900/10 disabled:cursor-not-allowed disabled:bg-zinc-100 disabled:text-zinc-500"
                    placeholder="Message the agent"
                    disabled={!@can_prompt?}
                    title={@prompt_disabled_reason}
                    aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                  >{@prompt}</textarea>
                  <div class="flex gap-2">
                    <button
                      id="send-prompt-button"
                      class="inline-flex h-10 flex-1 items-center justify-center gap-2 rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-50"
                      disabled={!@can_prompt?}
                      title={@prompt_disabled_reason}
                      aria-describedby={if(@prompt_disabled_reason, do: "run-control-notice")}
                    >
                      <.icon name="hero-paper-airplane" class="size-4" /> Send
                    </button>
                    <button
                      id="cancel-run-button"
                      type="button"
                      class="inline-flex h-10 items-center justify-center gap-2 rounded-md border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50"
                      phx-click="cancel"
                      disabled={!@can_cancel?}
                      title={@cancel_disabled_reason}
                      aria-describedby={if(@cancel_disabled_reason, do: "run-control-notice")}
                    >
                      <.icon name="hero-x-mark" class="size-4" /> Cancel
                    </button>
                  </div>
                </.form>
              </section>

              <details
                :if={@turn_summaries != []}
                id="run-turn-summary"
                class="group rounded-lg border border-zinc-200 bg-white p-3"
              >
                <summary class="cursor-pointer list-none marker:hidden">
                  <span class="flex items-center justify-between gap-3">
                    <span class="min-w-0">
                      <span class="block text-sm font-semibold text-zinc-950">Turns</span>
                      <span class="mt-0.5 block text-xs text-zinc-500">
                        Prompt, tool, decision, file, and terminal rollups
                      </span>
                    </span>
                    <span id="run-turn-summary-count" class="font-mono text-xs text-zinc-500">
                      {length(@turn_summaries)}
                    </span>
                  </span>
                </summary>
                <div class="mt-3 hidden space-y-3 border-t border-zinc-200 pt-3 group-open:block">
                  <article
                    :for={turn <- @turn_summaries}
                    id={"run-turn-#{turn.started_seq}"}
                    data-turn-status={turn.status}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="text-xs font-semibold uppercase text-zinc-500">
                          Turn {turn.index} · {turn_sequence_label(turn)}
                        </p>
                        <p class="mt-1 truncate text-sm font-semibold text-zinc-950">
                          {turn_prompt_preview(turn.prompt)}
                        </p>
                      </div>
                      <span class={turn_status_class(turn.status)}>
                        {turn_status_label(turn.status)}
                      </span>
                    </div>

                    <p
                      id={"run-turn-#{turn.started_seq}-agent-preview"}
                      class="mt-3 line-clamp-3 whitespace-pre-wrap rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-700"
                    >
                      {turn_agent_preview(turn.agent_text)}
                    </p>

                    <dl class="mt-3 grid grid-cols-2 gap-2 text-xs text-zinc-700 sm:grid-cols-5">
                      <div id={"run-turn-#{turn.started_seq}-time"}>
                        <dt class="font-semibold uppercase text-zinc-500">Time</dt>
                        <dd class="font-mono">{turn_time_label(turn)}</dd>
                      </div>
                      <div id={"run-turn-#{turn.started_seq}-tool-calls"}>
                        <dt class="font-semibold uppercase text-zinc-500">Tools</dt>
                        <dd class="font-mono">{turn.tool_calls}</dd>
                      </div>
                      <div id={"run-turn-#{turn.started_seq}-decisions"}>
                        <dt class="font-semibold uppercase text-zinc-500">Decisions</dt>
                        <dd class="font-mono">{turn.decisions}</dd>
                      </div>
                      <div id={"run-turn-#{turn.started_seq}-files"}>
                        <dt class="font-semibold uppercase text-zinc-500">Files</dt>
                        <dd class="font-mono">{turn.file_events}</dd>
                      </div>
                      <div id={"run-turn-#{turn.started_seq}-terminals"}>
                        <dt class="font-semibold uppercase text-zinc-500">Terminals</dt>
                        <dd class="font-mono">{turn.terminal_events}</dd>
                      </div>
                    </dl>

                    <p
                      :if={turn.error}
                      id={"run-turn-#{turn.started_seq}-error"}
                      class="mt-3 text-sm font-medium text-rose-700"
                    >
                      {turn.error}
                    </p>
                  </article>
                </div>
              </details>

              <details
                id="run-activity-timeline"
                class="group rounded-lg border border-zinc-200 bg-white p-3"
              >
                <summary class="cursor-pointer list-none marker:hidden">
                  <span class="flex items-center justify-between gap-3">
                    <span class="min-w-0">
                      <span class="block text-sm font-semibold text-zinc-950">
                        Activity timeline
                      </span>
                      <span class="mt-0.5 block text-xs text-zinc-500">
                        Raw protocol, tool, file, terminal, and runtime events
                      </span>
                    </span>
                    <span
                      id="run-activity-timeline-count"
                      class="rounded-md bg-zinc-100 px-2 py-1 font-mono text-xs text-zinc-600"
                    >
                      {@run_nav_counts.evidence}
                    </span>
                  </span>
                </summary>

                <div class="mt-3 hidden space-y-3 border-t border-zinc-200 pt-3 group-open:block">
                  <details
                    id="timeline-filters"
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <summary class="cursor-pointer text-sm font-medium text-zinc-700">
                      Filter activity
                    </summary>
                    <form
                      id="timeline-search-form"
                      phx-change="search_events"
                      phx-submit="search_events"
                      class="mt-3 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]"
                    >
                      <.input
                        id="event_search"
                        name="event_search"
                        value={@event_search}
                        type="search"
                        label="Search activity"
                        placeholder="Event type, tool id, path, command, output"
                        autocomplete="off"
                      />
                      <button
                        :if={@event_search != ""}
                        id="clear-timeline-search"
                        type="button"
                        class="mb-2 h-10 self-end rounded-md border border-zinc-300 bg-white px-3 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-50"
                        phx-click="clear_event_search"
                      >
                        Clear
                      </button>
                    </form>
                    <div class="mt-3 flex flex-wrap items-center gap-2">
                      <button
                        :for={{kind, label} <- @event_filters}
                        id={"timeline-filter-#{kind}"}
                        type="button"
                        phx-click="filter_events"
                        phx-value-kind={kind}
                        class={[
                          "inline-flex h-8 items-center rounded-md border px-3 text-xs font-semibold transition",
                          @event_filter == kind &&
                            "border-zinc-950 bg-zinc-950 text-white",
                          @event_filter != kind &&
                            "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50"
                        ]}
                      >
                        {label}
                        <span class="ml-1 text-[11px] opacity-70">
                          {Map.get(@event_counts, kind, 0)}
                        </span>
                      </button>
                    </div>
                  </details>
                  <div
                    :if={@timeline_entries == []}
                    id="timeline-empty-filter"
                    class="rounded-lg border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"
                  >
                    <%= if @event_search != "" do %>
                      No events match this search.
                    <% else %>
                      No events match this filter.
                    <% end %>
                  </div>
                  <.event
                    :for={entry <- @timeline_entries}
                    event={entry.event}
                    result_event={entry.result_event}
                    permission_audits={@permission_audits}
                  />
                </div>
              </details>
            </section>
          </div>

          <aside class="min-w-0 space-y-4">
            <section class="rounded-lg border border-zinc-200 bg-white p-4 text-sm shadow-sm">
              <h2 class="font-semibold">Run facts</h2>
              <dl class="mt-3 space-y-2">
                <div id="run-facts-agent">
                  <dt class="text-zinc-500">Agent</dt>
                  <dd class="font-mono">{@run.agent}</dd>
                  <dd class="mt-1 flex flex-wrap gap-1">
                    <span id="run-facts-agent-launch" class={agent_launch_class(@agent_readiness)}>
                      {agent_launch_label(@agent_readiness)}
                    </span>
                    <span
                      id="run-facts-agent-trust"
                      class={agent_evidence_class(@agent_readiness, @agent_probe_reports)}
                    >
                      {agent_evidence_label(@agent_readiness, @agent_probe_reports)}
                    </span>
                    <span
                      :if={@agent_capability_gap_reports != []}
                      id="run-facts-agent-capability-gaps"
                      class={capability_gap_class()}
                    >
                      {pluralize_count(length(@agent_capability_gap_reports), "capability gap")}
                    </span>
                  </dd>
                  <dd
                    id="run-facts-agent-evidence-reason"
                    class="mt-1 text-xs text-zinc-500"
                  >
                    {agent_evidence_reason(@agent_readiness, @agent_probe_reports)}
                  </dd>
                  <dd
                    :if={@agent_capability_gap_reports != []}
                    id="run-facts-agent-capability-gap-reason"
                    class="mt-1 text-xs text-amber-700"
                  >
                    {capability_gap_reason(@agent_capability_gap_reports)}
                  </dd>
                </div>
                <div id="run-facts-agent-cwd">
                  <dt class="text-zinc-500">Agent cwd</dt>
                  <dd class="break-all text-xs">{agent_launch_cwd_scope_label(@agent_readiness)}</dd>
                </div>
                <div id="run-facts-workspace">
                  <dt class="text-zinc-500">Workspace</dt>
                  <dd class="break-all text-xs">{workspace_identity_label(@workspace_summary)}</dd>
                  <dd class="mt-1">
                    <span
                      id="run-facts-workspace-state"
                      class={workspace_state_class(@workspace_summary)}
                    >
                      {workspace_state_label(@workspace_summary)}
                    </span>
                  </dd>
                  <dd class="mt-1 break-all text-xs text-zinc-500">{@run.workspace}</dd>
                </div>
                <div id="run-facts-agent-env-keys">
                  <dt class="text-zinc-500">Agent env</dt>
                  <dd class="mt-1 flex flex-wrap items-center gap-1 text-xs">
                    <span id="run-facts-agent-env-key-list" class="break-all">
                      {agent_launch_env_scope_label(@agent_readiness)}
                    </span>
                    <span
                      id="run-facts-agent-auth-env"
                      class={agent_launch_env_auth_class(@agent_readiness)}
                      title={agent_launch_env_auth_reason(@agent_readiness)}
                    >
                      {agent_launch_env_auth_label(@agent_readiness)}
                    </span>
                  </dd>
                  <dd
                    id="run-facts-agent-auth-reason"
                    class="mt-1 text-xs text-zinc-500"
                  >
                    {agent_launch_env_auth_reason(@agent_readiness)}
                  </dd>
                </div>
                <div id="run-facts-session">
                  <dt class="text-zinc-500">Agent session</dt>
                  <dd class="break-all">{@run.agent_session_id || "starting"}</dd>
                </div>
                <div id="run-facts-process">
                  <dt class="text-zinc-500">Process</dt>
                  <dd>{if @live?, do: "connected", else: "not connected"}</dd>
                </div>
                <div id="run-facts-created">
                  <dt class="text-zinc-500">Created</dt>
                  <dd class="font-mono text-xs">
                    {Calendar.strftime(@run.inserted_at, "%Y-%m-%d %H:%M:%S")}
                  </dd>
                </div>
                <div id="run-facts-updated">
                  <dt class="text-zinc-500">Updated</dt>
                  <dd class="font-mono text-xs">
                    {Calendar.strftime(@run.updated_at, "%Y-%m-%d %H:%M:%S")}
                  </dd>
                </div>
              </dl>
              <details
                :if={@agent_probe_reports != []}
                id="run-agent-probe-evidence"
                class="mt-4 border-t border-zinc-200 pt-3 text-xs"
              >
                <summary class="cursor-pointer font-semibold uppercase text-zinc-500">
                  Accepted probe artifacts
                </summary>
                <ul class="mt-2 space-y-1">
                  <li
                    :for={report <- @agent_probe_reports}
                    id={"run-agent-probe-#{Path.basename(report.path, ".json")}"}
                    class="truncate"
                    title={report.prompt}
                  >
                    {agent_probe_report_label(report)}
                  </li>
                </ul>
              </details>
              <details
                :if={@agent_capability_gap_reports != []}
                id="run-agent-capability-gap-evidence"
                class="mt-4 border-t border-zinc-200 pt-3 text-xs"
              >
                <summary class="cursor-pointer font-semibold uppercase text-amber-700">
                  Capability gap reports
                </summary>
                <div
                  id="run-agent-capability-gap-summary"
                  class="mt-2 rounded-md border border-amber-200 bg-amber-50 p-2 text-amber-900"
                >
                  <p class="font-semibold">Not proven for this agent</p>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <span
                      :for={family <- capability_gap_family_items(@agent_capability_gap_reports)}
                      id={"run-agent-capability-gap-family-#{policy_scope_id(family)}"}
                      class="inline-flex max-w-full rounded-full border border-amber-300 bg-white px-2 py-0.5 font-mono text-[11px] text-amber-900"
                    >
                      <span class="truncate">{family}</span>
                    </span>
                  </div>
                </div>
                <ul class="mt-2 space-y-1">
                  <li
                    :for={report <- @agent_capability_gap_reports}
                    id={"run-agent-capability-gap-#{Path.basename(report.path, ".json")}"}
                    class="truncate text-amber-800"
                    title={report.prompt}
                  >
                    {capability_gap_report_label(report)}
                  </li>
                </ul>
              </details>
              <section id="run-evidence-summary" class="mt-4 border-t border-zinc-200 pt-3">
                <h3 class="text-xs font-semibold uppercase text-zinc-500">Evidence</h3>
                <dl class="mt-2 grid grid-cols-2 gap-2 text-xs">
                  <div id="run-evidence-events" class="min-w-0">
                    <dt class="text-zinc-500">Timeline events</dt>
                    <dd class="font-mono text-sm text-zinc-950">{length(@events)}</dd>
                  </div>
                  <div id="run-evidence-decisions" class="min-w-0">
                    <dt class="text-zinc-500">Decisions</dt>
                    <dd class="font-mono text-sm text-zinc-950">{length(@permission_audits)}</dd>
                  </div>
                  <div id="run-evidence-file-changes" class="min-w-0">
                    <dt class="text-zinc-500">File changes</dt>
                    <dd class="font-mono text-sm text-zinc-950">{length(@file_changes)}</dd>
                  </div>
                  <div id="run-evidence-terminal-sessions" class="min-w-0">
                    <dt class="text-zinc-500">Terminal sessions</dt>
                    <dd class="font-mono text-sm text-zinc-950">{length(@terminal_sessions)}</dd>
                  </div>
                </dl>
              </section>
              <details id="run-capability-policy" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>Capability policy</span>
                  <span class="normal-case text-zinc-400">
                    {policy_label(@capability_policy["file_read"])} reads
                  </span>
                </summary>
                <dl class="mt-2 grid gap-2">
                  <div id="run-policy-file-read" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">File reads</dt>
                    <dd class={policy_badge_class(@capability_policy["file_read"])}>
                      {policy_label(@capability_policy["file_read"])}
                    </dd>
                  </div>
                  <div id="run-policy-file-read-paths" class="grid gap-1">
                    <dt class="text-zinc-500">Read paths</dt>
                    <dd class="flex flex-wrap gap-1">
                      <span
                        :for={scope <- policy_scope_items(@capability_policy["file_read_paths"])}
                        id={"run-policy-file-read-scope-#{policy_scope_id(scope)}"}
                        class={policy_scope_class(@capability_policy["file_read_paths"])}
                      >
                        <span class="truncate">{scope}</span>
                      </span>
                    </dd>
                  </div>
                  <div id="run-policy-file-write" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">File writes</dt>
                    <dd class={policy_badge_class(@capability_policy["file_write"])}>
                      {policy_label(@capability_policy["file_write"])}
                    </dd>
                  </div>
                  <div id="run-policy-file-write-paths" class="grid gap-1">
                    <dt class="text-zinc-500">Write paths</dt>
                    <dd class="flex flex-wrap gap-1">
                      <span
                        :for={scope <- policy_scope_items(@capability_policy["file_write_paths"])}
                        id={"run-policy-file-write-scope-#{policy_scope_id(scope)}"}
                        class={policy_scope_class(@capability_policy["file_write_paths"])}
                      >
                        <span class="truncate">{scope}</span>
                      </span>
                    </dd>
                  </div>
                  <div id="run-policy-terminal-create" class="flex items-center justify-between gap-3">
                    <dt class="text-zinc-500">Terminals</dt>
                    <dd class={policy_badge_class(@capability_policy["terminal_create"])}>
                      {policy_label(@capability_policy["terminal_create"])}
                    </dd>
                  </div>
                </dl>
                <section
                  id="run-security-boundary"
                  class="mt-3 border-t border-zinc-100 pt-2 text-xs text-zinc-600"
                >
                  <h4 class="font-semibold uppercase text-zinc-500">
                    Workspace security boundary
                  </h4>
                  <ul class="mt-1 grid gap-1 leading-5">
                    <li id="run-security-boundary-root">
                      Files are resolved inside this run's workspace root.
                    </li>
                    <li id="run-security-boundary-scopes">
                      Blank path scopes mean all workspace paths; scoped paths narrow access.
                    </li>
                    <li id="run-security-boundary-terminal">
                      Terminal working directories must stay inside the workspace.
                    </li>
                  </ul>
                </section>
              </details>
              <details id="run-permission-audit" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>Permission audit</span>
                  <span
                    id="run-permission-audit-count"
                    class="font-mono text-xs text-zinc-500"
                  >
                    {length(@permission_audits)}
                  </span>
                </summary>

                <div
                  :if={@permission_audits == []}
                  id="run-permission-audit-empty"
                  class="mt-2 rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500"
                >
                  No permission decisions recorded.
                </div>

                <div class="mt-3 space-y-3">
                  <article
                    :for={audit <- @permission_audits}
                    id={"permission-audit-#{audit.id}"}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <% request_event = permission_request_event_for_audit(@events, audit) %>
                    <% decision_event = permission_resolution_event_for_audit(@events, audit) %>
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate text-xs font-semibold text-zinc-900">
                          {audit.title || permission_kind_label(audit.kind)}
                        </p>
                        <p class="mt-1 font-mono text-[11px] text-zinc-500">
                          request {audit.request_id}
                        </p>
                      </div>
                      <span
                        id={"permission-audit-#{audit.id}-status"}
                        class={permission_status_class(audit.status)}
                      >
                        {audit.status}
                      </span>
                    </div>

                    <div class="mt-3 flex flex-wrap gap-2">
                      <a
                        :if={request_event}
                        id={"permission-audit-#{audit.id}-request-event-link"}
                        href={"#event-#{request_event.seq}"}
                        class="inline-flex items-center gap-1 text-xs font-semibold text-zinc-700 transition hover:text-zinc-950"
                      >
                        <.icon name="hero-arrow-down-circle" class="size-3.5" /> View request
                      </a>
                      <a
                        :if={decision_event}
                        id={"permission-audit-#{audit.id}-decision-event-link"}
                        href={"#event-#{decision_event.seq}"}
                        class="inline-flex items-center gap-1 text-xs font-semibold text-zinc-700 transition hover:text-zinc-950"
                      >
                        <.icon name="hero-arrow-down-circle" class="size-3.5" /> View decision
                      </a>
                    </div>

                    <dl class="mt-3 grid gap-2 text-xs text-zinc-700">
                      <div id={"permission-audit-#{audit.id}-requested-at"}>
                        <dt class="font-semibold uppercase text-zinc-500">Requested</dt>
                        <dd class="font-mono">{audit_time_label(audit.inserted_at)}</dd>
                      </div>
                      <div :if={audit.resolved_at} id={"permission-audit-#{audit.id}-resolved-at"}>
                        <dt class="font-semibold uppercase text-zinc-500">Resolved</dt>
                        <dd class="font-mono">{audit_time_label(audit.resolved_at)}</dd>
                      </div>
                      <div id={"permission-audit-#{audit.id}-kind"}>
                        <dt class="font-semibold uppercase text-zinc-500">Kind</dt>
                        <dd>{permission_kind_label(audit.kind)}</dd>
                      </div>
                      <div
                        :if={audit.tool_call_id}
                        id={"permission-audit-#{audit.id}-tool-call"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Tool call</dt>
                        <dd class="break-all font-mono">{audit.tool_call_id}</dd>
                      </div>
                      <div id={"permission-audit-#{audit.id}-options"}>
                        <dt class="font-semibold uppercase text-zinc-500">Options</dt>
                        <dd class="break-all font-mono">{permission_options_label(audit.options)}</dd>
                      </div>
                      <div
                        :if={audit.selected_option_id}
                        id={"permission-audit-#{audit.id}-selected-option"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Selected</dt>
                        <dd class="font-mono">{audit.selected_option_id}</dd>
                      </div>
                      <div :if={audit.actor} id={"permission-audit-#{audit.id}-actor"}>
                        <dt class="font-semibold uppercase text-zinc-500">Actor</dt>
                        <dd class="font-mono">{audit.actor}</dd>
                      </div>
                      <div :if={audit.reason} id={"permission-audit-#{audit.id}-reason"}>
                        <dt class="font-semibold uppercase text-zinc-500">Reason</dt>
                        <dd class="break-all font-mono">{audit.reason}</dd>
                      </div>
                    </dl>

                    <pre
                      :if={audit.raw_input && audit.raw_input != %{}}
                      id={"permission-audit-#{audit.id}-raw-input"}
                      class="mt-3 max-h-32 overflow-auto rounded-md bg-white p-3 text-xs text-zinc-800 ring-1 ring-zinc-200"
                    ><%= Jason.encode!(audit.raw_input, pretty: true) %></pre>
                  </article>
                </div>
              </details>
              <details id="run-file-changes" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>File changes</span>
                  <span class="flex min-w-0 items-center gap-2">
                    <span
                      id="run-file-change-summary-label"
                      class="truncate font-medium normal-case text-zinc-600"
                    >
                      {file_change_summary_label(@file_change_counts)}
                    </span>
                    <span id="run-file-change-count" class="font-mono text-xs text-zinc-500">
                      {length(@file_changes)}
                    </span>
                  </span>
                </summary>

                <div
                  :if={@file_changes == []}
                  id="run-file-changes-empty"
                  class="mt-2 rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500"
                >
                  No file changes recorded.
                </div>

                <div
                  :if={@file_changes != []}
                  id="run-file-change-review-summary"
                  class="mt-3 grid grid-cols-3 gap-2 text-xs"
                >
                  <div class="rounded-md border border-amber-200 bg-amber-50 p-2">
                    <p class="font-semibold uppercase text-amber-700">Needs review</p>
                    <p id="run-file-change-pending-count" class="mt-1 font-mono text-zinc-900">
                      {@file_change_counts["pending"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-emerald-200 bg-emerald-50 p-2">
                    <p class="font-semibold uppercase text-emerald-700">Applied</p>
                    <p id="run-file-change-applied-count" class="mt-1 font-mono text-zinc-900">
                      {@file_change_counts["applied"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-rose-200 bg-rose-50 p-2">
                    <p class="font-semibold uppercase text-rose-700">Blocked</p>
                    <p id="run-file-change-blocked-count" class="mt-1 font-mono text-zinc-900">
                      {@file_change_counts["blocked"]}
                    </p>
                  </div>
                </div>

                <div class="mt-3 space-y-3">
                  <article
                    :for={change <- @file_changes}
                    id={"file-change-#{change.change_id}"}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate font-mono text-xs font-semibold text-zinc-900">
                          {change.path}
                        </p>
                        <p class="mt-1 font-mono text-[11px] text-zinc-500">
                          {change.diff_kind}
                        </p>
                      </div>
                      <span
                        id={"file-change-#{change.change_id}-status"}
                        class={file_change_status_class(change.status)}
                      >
                        {change.status}
                      </span>
                    </div>
                    <p
                      id={"file-change-#{change.change_id}-review-state"}
                      class="mt-3 rounded-md border border-zinc-200 bg-white px-3 py-2 text-xs text-zinc-600"
                    >
                      <span class="font-semibold text-zinc-900">
                        {file_change_review_label(change)}
                      </span>
                      {" · "}{file_change_review_hint(change)}
                    </p>

                    <dl class="mt-3 grid gap-2 text-xs text-zinc-700">
                      <div
                        :if={change.resolved_path}
                        id={"file-change-#{change.change_id}-resolved-path"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Resolved path</dt>
                        <dd class="break-all font-mono">{change.resolved_path}</dd>
                      </div>
                      <div id={"file-change-#{change.change_id}-bytes"}>
                        <dt class="font-semibold uppercase text-zinc-500">Bytes</dt>
                        <dd class="font-mono">{change.bytes}</dd>
                      </div>
                      <div id={"file-change-#{change.change_id}-existing-bytes"}>
                        <dt class="font-semibold uppercase text-zinc-500">Existing bytes</dt>
                        <dd class="font-mono">{change.existing_bytes || 0}</dd>
                      </div>
                    </dl>

                    <p
                      :if={file_change_error(change.error)}
                      id={"file-change-#{change.change_id}-error"}
                      class="mt-3 text-xs font-medium text-rose-700"
                    >
                      {file_change_error(change.error)}
                    </p>

                    <pre
                      :if={file_change_preview(change.content_preview)}
                      id={"file-change-#{change.change_id}-content"}
                      class="mt-3 max-h-32 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
                    ><%= change.content_preview %></pre>
                    <p
                      :if={change.content_truncated}
                      id={"file-change-#{change.change_id}-content-truncated"}
                      class="mt-2 text-xs font-medium text-amber-700"
                    >
                      Content preview truncated.
                    </p>

                    <pre
                      :if={file_change_preview(change.diff_preview)}
                      id={"file-change-#{change.change_id}-diff"}
                      class="mt-3 max-h-40 overflow-auto rounded-md bg-white p-3 text-xs text-zinc-800 ring-1 ring-zinc-200"
                    ><%= change.diff_preview %></pre>
                    <p
                      :if={change.diff_truncated}
                      id={"file-change-#{change.change_id}-diff-truncated"}
                      class="mt-2 text-xs font-medium text-amber-700"
                    >
                      Diff preview truncated.
                    </p>
                  </article>
                </div>
              </details>
              <details id="run-terminal-sessions" class="mt-4 border-t border-zinc-200 pt-3">
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 py-1 text-xs font-semibold uppercase text-zinc-500 marker:hidden">
                  <span>Terminal sessions</span>
                  <span class="flex min-w-0 items-center gap-2">
                    <span
                      id="run-terminal-session-summary-label"
                      class="truncate font-medium normal-case text-zinc-600"
                    >
                      {terminal_session_summary_label(@terminal_session_counts)}
                    </span>
                    <span
                      id="run-terminal-session-count"
                      class="font-mono text-xs text-zinc-500"
                    >
                      {length(@terminal_sessions)}
                    </span>
                  </span>
                </summary>

                <div
                  :if={@terminal_sessions == []}
                  id="run-terminal-sessions-empty"
                  class="mt-2 rounded-md border border-dashed border-zinc-300 p-3 text-xs text-zinc-500"
                >
                  No terminal sessions recorded.
                </div>

                <div
                  :if={@terminal_sessions != []}
                  id="run-terminal-session-summary"
                  class="mt-3 grid grid-cols-3 gap-2 text-xs"
                >
                  <div class="rounded-md border border-sky-200 bg-sky-50 p-2">
                    <p class="font-semibold uppercase text-sky-700">Running</p>
                    <p id="run-terminal-session-running-count" class="mt-1 font-mono text-zinc-900">
                      {@terminal_session_counts["running"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-emerald-200 bg-emerald-50 p-2">
                    <p class="font-semibold uppercase text-emerald-700">Completed</p>
                    <p id="run-terminal-session-completed-count" class="mt-1 font-mono text-zinc-900">
                      {@terminal_session_counts["completed"]}
                    </p>
                  </div>
                  <div class="rounded-md border border-rose-200 bg-rose-50 p-2">
                    <p class="font-semibold uppercase text-rose-700">Needs attention</p>
                    <p id="run-terminal-session-attention-count" class="mt-1 font-mono text-zinc-900">
                      {@terminal_session_counts["attention"]}
                    </p>
                  </div>
                </div>

                <div class="mt-3 space-y-3">
                  <article
                    :for={session <- @terminal_sessions}
                    id={"terminal-session-#{session.terminal_id}"}
                    class="rounded-md border border-zinc-200 bg-zinc-50 p-3"
                  >
                    <div class="flex min-w-0 items-start justify-between gap-3">
                      <div class="min-w-0">
                        <p class="truncate font-mono text-xs font-semibold text-zinc-900">
                          {session.command}
                        </p>
                        <p class="mt-1 break-all font-mono text-[11px] text-zinc-500">
                          {session.terminal_id}
                        </p>
                      </div>
                      <span
                        id={"terminal-session-#{session.terminal_id}-status"}
                        class={terminal_status_class(session.status)}
                      >
                        {session.status}
                      </span>
                    </div>
                    <p
                      id={"terminal-session-#{session.terminal_id}-review-state"}
                      class="mt-3 rounded-md border border-zinc-200 bg-white px-3 py-2 text-xs text-zinc-600"
                    >
                      <span class="font-semibold text-zinc-900">
                        {terminal_review_label(session)}
                      </span>
                      {" · "}{terminal_review_hint(session)}
                    </p>

                    <dl class="mt-3 grid gap-2 text-xs text-zinc-700">
                      <div id={"terminal-session-#{session.terminal_id}-args"}>
                        <dt class="font-semibold uppercase text-zinc-500">Arguments</dt>
                        <dd class="break-all font-mono">{terminal_args_label(session.args)}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-cwd"}>
                        <dt class="font-semibold uppercase text-zinc-500">Working directory</dt>
                        <dd class="break-all font-mono">{session.cwd}</dd>
                      </div>
                      <div
                        :if={session.executable}
                        id={"terminal-session-#{session.terminal_id}-executable"}
                      >
                        <dt class="font-semibold uppercase text-zinc-500">Executable</dt>
                        <dd class="break-all font-mono">{session.executable}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-exit"}>
                        <dt class="font-semibold uppercase text-zinc-500">Exit status</dt>
                        <dd class="font-mono">{terminal_exit_label(session.exit_status)}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-bytes"}>
                        <dt class="font-semibold uppercase text-zinc-500">Output bytes</dt>
                        <dd class="font-mono">{session.output_bytes}</dd>
                      </div>
                      <div id={"terminal-session-#{session.terminal_id}-env"}>
                        <dt class="font-semibold uppercase text-zinc-500">Env keys</dt>
                        <dd class="break-all font-mono">
                          {terminal_env_keys_label(session.env_keys)}
                        </dd>
                      </div>
                    </dl>

                    <pre
                      :if={terminal_output_preview(session.output_preview)}
                      id={"terminal-session-#{session.terminal_id}-output"}
                      class="mt-3 max-h-32 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-zinc-50"
                    ><%= session.output_preview %></pre>
                    <p
                      :if={session.output_truncated}
                      id={"terminal-session-#{session.terminal_id}-truncated"}
                      class="mt-2 text-xs font-medium text-amber-700"
                    >
                      Output preview truncated.
                    </p>
                  </article>
                </div>
              </details>
              <button
                :if={@can_reconnect?}
                id="reconnect-run-button"
                type="button"
                class="mt-4 h-10 w-full rounded-md bg-zinc-950 px-4 text-sm font-semibold text-white transition hover:bg-zinc-800"
                phx-click="reconnect"
              >
                {if @run.status == "failed", do: "Restart", else: "Reconnect"}
              </button>
            </section>
          </aside>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
