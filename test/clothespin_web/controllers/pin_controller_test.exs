defmodule ClothespinWeb.PinControllerTest do
  use ClothespinWeb.ConnCase, async: true

  alias Clothespin.{Accounts, Pins, Relay}

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "pinuser",
        display_name: "Pin User",
        passphrase: "pin passphrase 123"
      })

    {:ok, room} = Pins.create_room(user, "web room")
    conn = Plug.Test.init_test_session(build_conn(), %{}) |> put_session(:user_id, user.id)
    %{conn: conn, user: user, room: room}
  end

  test "GET /pins/:id renders room page for a member", %{conn: conn, room: room} do
    html = html_response(get(conn, "/pins/#{room.id}"), 200)
    assert html =~ "web room"
    assert html =~ "Invite a teammate"
    assert html =~ "Generate bridge token"
  end

  test "GET /pins/:id redirects non-members", %{conn: conn, room: room} do
    {:ok, outsider} =
      Accounts.create_user(%{
        username: "outsider",
        display_name: "Out",
        passphrase: "outsider passphrase"
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_session(:user_id, outsider.id)

    assert redirected_to(get(conn, "/pins/#{room.id}")) == "/"
  end

  test "POST message fallback records, broadcasts, and redirects", %{conn: conn, room: room} do
    {:ok, conversation} =
      Relay.upsert_conversation(room, %{title: "thread", created_by: "human:pinuser"})

    ClothespinWeb.Endpoint.subscribe("room:#{room.id}")

    conn =
      post(conn, "/pins/#{room.id}/conversations/#{conversation.id}/messages", %{
        "_csrf_token" => get_csrf_token(),
        "client_message_id" => "web-cmid-1",
        "body" => "posted over http"
      })

    assert redirected_to(conn) == "/pins/#{room.id}?cid=#{conversation.id}"
    assert_receive %{event: "message_new", payload: %{body: "posted over http"}}
    snapshot = Relay.snapshot(room)
    assert [%{body: "posted over http", sender_key: "human:pinuser"}] = snapshot.messages
  end

  test "POST bridge-token shows the command", %{conn: conn, room: room} do
    conn = post(conn, "/pins/#{room.id}/bridge-token", %{"_csrf_token" => get_csrf_token()})
    html = html_response(conn, 200)
    assert html =~ "mix pin.connect --server"
    assert html =~ "--bridge-token"
  end

  test "join flow: valid invite adds membership", %{conn: conn, user: user, room: room} do
    {:ok, other} =
      Accounts.create_user(%{
        username: "joiner",
        display_name: "Joiner",
        passphrase: "joiner passphrase"
      })

    other_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_session(:user_id, other.id)

    invite = Pins.invite_token(room, user)
    html = html_response(get(other_conn, "/join/#{invite}"), 200)
    assert html =~ "Join pin"

    conn = post(other_conn, "/join/#{invite}", %{"_csrf_token" => get_csrf_token()})
    assert redirected_to(conn) == "/pins/#{room.id}"
    assert Pins.member?(other, room)
  end
end
