defmodule ClothespinWeb.RoomChannelTest do
  use ClothespinWeb.ChannelCase, async: true

  alias Clothespin.{Accounts, Pins, Relay}
  alias ClothespinWeb.Presence
  alias ClothespinWeb.RoomChannel
  alias ClothespinWeb.UserSocket

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "channeluser",
        display_name: "Channel User",
        passphrase: "channel passphrase 1"
      })

    {:ok, room} = Pins.create_room(user, "channel room")

    token =
      Phoenix.Token.sign(ClothespinWeb.Endpoint, "user_socket", %{
        user_id: user.id,
        room_id: room.id,
        name: user.username
      })

    {:ok, _, socket} =
      socket(UserSocket, "socket_id", %{token: token})
      |> Phoenix.Socket.assign(:user_id, user.id)
      |> subscribe_and_join(RoomChannel, "room:#{room.id}")

    on_exit(fn -> :ok end)

    %{socket: socket, user: user, room: room}
  end

  test "join replies and pushes a snapshot", %{room: room} do
    assert_push "snapshot", %{messages: [], conversations: []}
    assert Presence.list("room:#{room.id}") != %{}
  end

  test "chat persists, broadcasts, and replies with the message id", %{socket: socket, room: room} do
    {:ok, conversation} =
      Relay.upsert_conversation(room, %{title: "web thread", created_by: "human:channeluser"})

    ref =
      push(socket, "chat", %{
        conversation_id: conversation.id,
        client_message_id: "cm-web-1",
        body: "hello from the browser"
      })

    assert_reply ref, :ok, %{message_id: message_id}
    assert_push "message_new", %{body: "hello from the browser", sender_kind: "human"}

    snapshot = Relay.snapshot(room)
    assert [%{id: ^message_id}] = snapshot.messages
  end

  test "open_conversation creates a web conversation and broadcasts it", %{socket: socket} do
    ref = push(socket, "open_conversation", %{title: "fresh thread"})
    assert_reply ref, :ok, %{conversation_id: conversation_id}
    assert_push "conversation_new", %{id: ^conversation_id, title: "fresh thread"}
  end

  test "unknown ops error", %{socket: socket} do
    ref = push(socket, "bogus", %{})
    assert_reply ref, :error, %{reason: "unknown op"}
  end
end
