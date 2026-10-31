defmodule ClothespinWeb.RoomChannel do
  @moduledoc """
  Browser chat in a pin. Join is membership-gated; `chat` is the synchronous
  send → persist → broadcast → ack path.
  """

  use ClothespinWeb, :channel
  alias Clothespin.Pins
  alias Clothespin.Relay
  alias ClothespinWeb.Presence

  @impl true
  def join("room:" <> room_id, _payload, socket) do
    user = Clothespin.Accounts.get_user(socket.assigns.user_id)

    with %Pins.Room{} = room <- Pins.get_room(room_id),
         true <- Pins.member?(user, room) do
      send(self(), :after_join)
      {:ok, %{}, assign(socket, room: room, user: user)}
    else
      _ -> {:error, %{reason: "not a member of this pin"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    %{room: room, user: user} = socket.assigns

    Presence.track(socket, user.username, %{
      name: user.display_name,
      joined_at: System.system_time(:millisecond)
    })

    snapshot = Relay.snapshot(room)

    push(socket, "snapshot", %{
      messages: Enum.map(snapshot.messages, &message_view/1),
      conversations: Enum.map(snapshot.conversations, &conversation_view/1)
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "chat",
        %{"conversation_id" => cid, "client_message_id" => cmid, "body" => body},
        socket
      ) do
    %{room: room, user: user} = socket.assigns

    with %Relay.Conversation{} = conversation <- Relay.get_conversation(room.id, cid),
         {:ok, message, _duplicate} <-
           Relay.record_message(room, %{
             conversation: conversation,
             sender_key: "human:#{user.username}",
             sender_name: user.display_name,
             sender_site: nil,
             client_message_id: cmid,
             body: body
           }) do
      payload = Relay.message_payload(message, conversation)
      broadcast!(socket, "message_new", payload)
      {:reply, {:ok, %{message_id: message.id}}, socket}
    else
      nil -> {:reply, {:error, %{reason: "unknown conversation"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("open_conversation", %{"title" => title} = params, socket) do
    %{room: room, user: user} = socket.assigns

    case Relay.upsert_conversation(room, %{
           title: title,
           project_key: params["project_key"],
           created_by: "human:#{user.username}"
         }) do
      {:ok, conversation} ->
        broadcast!(socket, "conversation_new", conversation_view(conversation))
        {:reply, {:ok, %{conversation_id: conversation.id}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "a title is required"}}, socket}
    end
  end

  def handle_in(_op, _payload, socket) do
    {:reply, {:error, %{reason: "unknown op"}}, socket}
  end

  defp message_view(%Relay.Message{} = message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_key: message.sender_key,
      sender_name: message.sender_name,
      sender_site: message.sender_site,
      recipient_site: message.recipient_site,
      body: message.body,
      inserted_at: message.inserted_at
    }
  end

  defp conversation_view(%Relay.Conversation{} = conversation) do
    %{
      id: conversation.id,
      title: conversation.title,
      project_key: conversation.project_key,
      origin_site: conversation.origin_site
    }
  end
end
