defmodule ClothespinWeb.BridgeSock do
  @moduledoc """
  The `/bridge` WebSocket: a trivial JSON frame protocol spoken by bridge
  daemons (step 7) instead of the phoenix.js wire protocol.

  Frames in: `{"op": ..., "ref": n, ...}` — frames out: replies
  `{"ok": true|false, "ref": n, "payload": ...}` and pushes `{"op": ...}`.

  Ops: `hello`, `message`, `agent_event`, `heartbeat`, `ping`. All relay work
  goes through `Clothespin.Relay`; routing pushes go through
  `Clothespin.SiteRegistry`.
  """

  alias Clothespin.{Relay, SiteRegistry}
  alias ClothespinWeb.Endpoint

  @behaviour WebSock

  @site_re ~r/^[a-z0-9][a-z0-9-]{0,63}$/

  @impl true
  def init(%{room: room}) do
    Endpoint.subscribe("room:#{room.id}")
    Endpoint.subscribe("bridge:#{room.id}")

    {:ok,
     %{
       room: room,
       site: nil
     }}
  end

  @impl true
  # Bandit's websock adapter passes {data, [opcode: :text]} — the opcode
  # arrives as a keyword list, not a bare atom.
  def handle_in({text, [opcode: :text]}, state), do: handle_text(text, state)
  def handle_in({text, :text}, state), do: handle_text(text, state)

  def handle_in({_binary, [opcode: :binary]}, state),
    do: error_reply(nil, "binary frames not supported", state)

  def handle_in({_binary, :binary}, state),
    do: error_reply(nil, "binary frames not supported", state)

  defp handle_text(text, state) do
    case Jason.decode(text) do
      {:ok, %{"op" => op, "ref" => ref} = frame} when is_integer(ref) ->
        if state.site || op in ["hello", "ping"] do
          handle_op(op, frame, ref, state)
        else
          error_reply(ref, "say hello first", state)
        end

      _ ->
        {:stop, :normal, {4002, "malformed frame"}, state}
    end
  end

  @impl true
  def handle_info({:push, text}, state) do
    {:push, [{:text, text}], state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "message_new", payload: payload, topic: "room:" <> _},
        state
      ) do
    # Only human/web chat reaches bridges through the room topic; bridged
    # messages (sender_site set) are direct-sent per the routing in handle_op.
    if is_map(payload) and is_nil(payload[:sender_site] || payload["sender_site"]) do
      {:push, [{:text, Jason.encode!(%{op: "message_new", payload: payload})}], state}
    else
      {:ok, state}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, state)
      when event in ["agent_event", "conversation_new"] do
    {:push, [{:text, Jason.encode!(%{op: event, payload: payload})}], state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{site: site, room: room}) when is_binary(site) do
    SiteRegistry.unregister(room.id, site)
  end

  def terminate(_reason, _state), do: :ok

  ## Ops

  defp handle_op("hello", %{"site_name" => site_name} = frame, ref, state) do
    site_name = String.downcase(site_name || "")

    if site_name =~ @site_re do
      case frame["announce"] do
        agents when is_list(agents) ->
          Enum.each(agents, &announce_agent(state.room, site_name, &1))

        _ ->
          :ok
      end

      SiteRegistry.register(state.room.id, site_name, self())

      snapshot = Relay.snapshot(state.room)

      reply(
        ref,
        %{
          site_id: site_name,
          snapshot: %{
            messages:
              Enum.map(
                snapshot.messages,
                &Relay.message_payload(&1, conversation_of(&1, snapshot))
              ),
            agents: Enum.map(snapshot.agents, &agent_view/1),
            conversations: Enum.map(snapshot.conversations, &conversation_view/1)
          }
        },
        %{state | site: site_name}
      )
    else
      error_reply(ref, "site_name must match #{Regex.source(@site_re)}", state)
    end
  end

  defp handle_op("message", frame, ref, state) do
    site = state.site
    room = state.room

    with {:ok, conversation} <- upsert_from_frame(room, frame["conversation"] || %{}),
         {:ok, message, duplicate} <-
           Relay.record_message(room, %{
             conversation: conversation,
             sender_key: "agent:#{site}:#{frame["sender_agent_ref"]}",
             sender_name: frame["sender_external_id"] || frame["sender_agent_ref"],
             sender_site: site,
             recipient_site: frame["recipient_site"],
             recipient_agent_ref: frame["recipient_agent_ref"],
             client_message_id: frame["client_message_id"] || "",
             body: frame["body"] || ""
           }) do
      unless duplicate do
        payload = Relay.message_payload(message, conversation)

        # Browsers see everything.
        Endpoint.broadcast_from(self(), "room:#{room.id}", "message_new", payload)

        # Other bridges: direct → only the recipient site; broadcast → all but us.
        routing = Relay.route(message)

        targets =
          (routing.direct_sites ++ if(routing.broadcast, do: SiteRegistry.sites(room.id), else: []))
          |> List.delete(site)
          |> Enum.uniq()

        Enum.each(targets, fn target_site ->
          case SiteRegistry.site_pid(room.id, target_site) do
            nil ->
              :ok

            pid ->
              send(pid, {:push, Jason.encode!(%{op: "message_new", payload: payload})})
          end
        end)
      end

      reply(ref, %{message_id: message.id, duplicate: duplicate}, state)
    else
      {:error, :title_required} ->
        error_reply(ref, "conversation title required", state)

      {:error, :origin_ref_required} ->
        error_reply(ref, "origin_ref required for foreign conversations", state)

      {:error, reason} ->
        error_reply(ref, inspect(reason), state)
    end
  end

  defp handle_op("agent_event", frame, ref, state) do
    site = state.site
    room = state.room

    attrs = %{
      site_name: site,
      agent_ref: frame["agent_ref"] || "",
      external_id: frame["external_id"],
      event: frame["event"] || "online",
      status_message: frame["status_message"]
    }

    case Relay.record_agent_event(room, attrs) do
      {:ok, agent} ->
        payload = agent_view(agent)

        # Mirror upkeep is recipient-driven: every other site mirrors every
        # foreign agent, so push to all other bridges and to browsers.
        Enum.each(SiteRegistry.pids_except(room.id, site), fn pid ->
          send(pid, {:push, Jason.encode!(%{op: "agent_event", payload: payload})})
        end)

        Endpoint.broadcast_from(self(), "room:#{room.id}", "agent_event", payload)
        reply(ref, %{recorded: true}, state)

      {:error, reason} ->
        error_reply(ref, inspect(reason), state)
    end
  end

  defp handle_op("heartbeat", frame, ref, state) do
    site = state.site
    room = state.room

    Enum.each(frame["agent_refs"] || [], fn agent_ref ->
      Relay.record_agent_event(room, %{
        site_name: site,
        agent_ref: agent_ref,
        event: "heartbeat"
      })
    end)

    reply(ref, %{bridges: SiteRegistry.sites(room.id)}, state)
  end

  defp handle_op("ping", _frame, ref, state) do
    reply(ref, %{pong: true, bridges: SiteRegistry.sites(state.room.id)}, state)
  end

  defp handle_op(op, _frame, ref, state), do: error_reply(ref, "unknown op #{op}", state)

  ## Helpers

  defp upsert_from_frame(room, %{"origin_site" => origin_site, "origin_ref" => origin_ref} = conv)
       when is_binary(origin_site) and is_binary(origin_ref) do
    Relay.upsert_conversation(room, %{
      origin_site: origin_site,
      origin_ref: origin_ref,
      title: conv["title"] || "bridged conversation",
      project_key: conv["project_key"],
      created_by: "agent:#{origin_site}"
    })
  end

  defp upsert_from_frame(room, conv) do
    Relay.upsert_conversation(room, %{
      title: conv["title"] || "bridged conversation",
      project_key: conv["project_key"],
      created_by: conv["created_by"]
    })
  end

  defp announce_agent(room, site, %{"agent_ref" => agent_ref} = agent) do
    Relay.record_agent_event(room, %{
      site_name: site,
      agent_ref: agent_ref,
      external_id: agent["external_id"],
      event: agent["event"] || "online",
      status_message: agent["status_message"]
    })
  end

  defp announce_agent(_room, _site, _), do: :ok

  defp conversation_of(%Relay.Message{conversation_id: cid}, %{conversations: conversations}) do
    Enum.find(conversations, &(&1.id == cid)) || %Relay.Conversation{id: cid, title: "unknown"}
  end

  defp agent_view(%Relay.RoomAgent{} = agent) do
    %{
      site_name: agent.site_name,
      agent_ref: agent.agent_ref,
      external_id: agent.external_id,
      state: agent.state,
      status_message: agent.status_message,
      last_seen_at: agent.last_seen_at
    }
  end

  defp conversation_view(%Relay.Conversation{} = conversation) do
    %{
      id: conversation.id,
      title: conversation.title,
      project_key: conversation.project_key,
      origin_site: conversation.origin_site,
      origin_ref: conversation.origin_ref
    }
  end

  defp reply(ref, payload, state) do
    {:reply, :ok,
     [
       {:text, Jason.encode!(%{ok: true, ref: ref, payload: payload})}
     ], state}
  end

  defp error_reply(ref, message, state) do
    {:push, [{:text, Jason.encode!(%{ok: false, ref: ref, error: message})}], state}
  end
end
