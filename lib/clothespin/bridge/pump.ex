defmodule Clothespin.Bridge.Pump do
  @moduledoc """
  Local bus → pin. Three cadences:

  * every `poll_ms`: poll `poll_messages` as each hosted mirror. Messages
    from our own mirrors are acked and skipped (injection echoes); messages
    from local agents are forwarded to the pin.
  * every 30s: diff `list_agents` and announce local-agent presence changes.
  * every 10min: heartbeat + re-online every mirror so clothesline keeps
    them eligible for broadcast delivery (STALE_AFTER is 3600s, we use 600s).
  """

  use GenServer

  alias Clothespin.Bridge.{Link, McpClient, Registry}

  @diff_every 30_000
  @heartbeat_every 600_000

  defstruct poll_ms: 2_000, last_announce: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    poll_ms = Keyword.get(opts, :poll_ms, 2_000)

    :timer.send_interval(poll_ms, :poll)
    :timer.send_interval(@diff_every, :diff)
    :timer.send_interval(@heartbeat_every, :heartbeat)

    # Start presence immediately instead of waiting for the first tick.
    send(self(), :diff)
    {:ok, %__MODULE__{poll_ms: poll_ms}}
  end

  @impl true
  def handle_info(:poll, state) do
    if Link.connected?() do
      # Poll as the bridge agent too: it receives every local broadcast, so
      # outbound forwarding works even before any mirror shares a
      # conversation. Its own injections are skipped by the mirror-sender
      # rule plus the explicit bridge-agent check in poll_mirror.
      Enum.each(Registry.list_mirrors(), &poll_mirror/1)
      poll_bridge_agent()
    end

    {:noreply, state}
  end

  def handle_info(:diff, state) do
    if Link.connected?() do
      {:noreply, announce_local_agents(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state) do
    if Link.connected?() do
      Enum.each(Registry.list_mirrors(), &heartbeat_mirror/1)
      heartbeat_bridge_agent()
    end

    {:noreply, state}
  end

  ## Internals

  defp poll_mirror(mirror), do: poll_as(mirror)

  defp poll_as(poller) do
    url = Registry.mcp_url()
    harness = Registry.harness_id()
    bridge_agent_id = Registry.bridge_agent().agent_id

    case McpClient.tool(url, "poll_messages", %{
           "harness_id" => harness,
           "agent_id" => poller.agent_id,
           "limit" => 50
         }) do
      {:ok, %{"messages" => []}} ->
        :ok

      {:ok, %{"messages" => messages}} ->
        Enum.each(messages, fn message ->
          sender_id = message["sender_agent_id"]

          if sender_id == poller.agent_id or sender_id == bridge_agent_id or
               Registry.mirror_by_agent_id(sender_id) do
            # Injection echo (ours or another pin-originated row) — bus-local only.
            :ok
          else
            forward_message(poller, message)
          end

          McpClient.tool(url, "ack_message", %{
            "harness_id" => harness,
            "agent_id" => poller.agent_id,
            "message_id" => message["id"]
          })
        end)

        max_id = messages |> Enum.map(& &1["id"]) |> Enum.max()
        Registry.put_cursor(poller.agent_id, max_id)

      {:error, _reason} ->
        :ok
    end
  end

  defp forward_message(_poller, message) do
    sender_id = message["sender_agent_id"]

    # An agent registered after our last 30s diff isn't in the local cache
    # yet; refresh once instead of dropping its message (we ack right after).
    sender =
      Registry.local_agent(sender_id) ||
        (Registry.refresh_locals() && Registry.local_agent(sender_id))

    if sender do
      conv_info =
        Registry.local_conv_info(message["conversation_id"]) ||
          %{title: "bridged conversation", project_key: nil}

      recipient_mirror =
        case message["recipient_agent_id"] do
          nil -> nil
          recipient_id -> Registry.mirror_by_agent_id(recipient_id)
        end

      frame = %{
        "conversation" => %{
          "origin_site" => Registry.site(),
          "origin_ref" => message["conversation_id"],
          "title" => conv_info.title,
          "project_key" => conv_info.project_key
        },
        "client_message_id" => message["client_message_id"],
        "sender_agent_ref" => sender["external_id"],
        "sender_external_id" => sender["external_id"],
        "body" => message["body"] || ""
      }

      frame =
        if recipient_mirror do
          Map.merge(frame, %{
            "recipient_site" => recipient_mirror.site,
            "recipient_agent_ref" => recipient_mirror.agent_ref
          })
        else
          frame
        end

      Link.call("message", frame)
    end
  end

  defp announce_local_agents(state) do
    harness = Registry.harness_id()

    case McpClient.tool(Registry.mcp_url(), "list_agents", %{"include_inactive" => true}) do
      {:ok, %{"agents" => agents}} ->
        locals =
          Enum.filter(agents, fn a ->
            a["harness_id"] != harness and
              is_binary(a["external_id"]) and
              not String.starts_with?(a["external_id"], "pin:")
          end)

        Registry.put_local_agents(locals)

        latest =
          Map.new(locals, fn a ->
            {a["id"], {a["status"], a["status_message"]}}
          end)

        Enum.each(latest, fn {agent_id, {status, status_message}} = entry ->
          if Map.get(state.last_announce, agent_id) != entry do
            if agent = Enum.find(locals, &(&1["id"] == agent_id)) do
              Link.call("agent_event", %{
                "agent_ref" => agent["external_id"],
                "external_id" => agent["external_id"],
                "event" => if(status == "offline", do: "offline", else: status || "online"),
                "status_message" => status_message
              })
            end
          end
        end)

        %{state | last_announce: latest}

      _ ->
        state
    end
  end

  defp heartbeat_mirror(mirror) do
    url = Registry.mcp_url()
    harness = Registry.harness_id()

    McpClient.tool(url, "agent_heartbeat", %{"harness_id" => harness, "agent_id" => mirror.agent_id})
    McpClient.tool(url, "agent_online", %{"harness_id" => harness, "agent_id" => mirror.agent_id})
  end

  defp poll_bridge_agent do
    bridge = Registry.bridge_agent()
    poll_as(%{agent_id: bridge.agent_id, site: nil, agent_ref: nil})
  end

  defp heartbeat_bridge_agent do
    bridge = Registry.bridge_agent()
    url = Registry.mcp_url()
    harness = Registry.harness_id()

    McpClient.tool(url, "agent_heartbeat", %{"harness_id" => harness, "agent_id" => bridge.agent_id})
    McpClient.tool(url, "agent_online", %{"harness_id" => harness, "agent_id" => bridge.agent_id})
  end
end
