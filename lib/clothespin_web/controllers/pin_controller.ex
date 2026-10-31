defmodule ClothespinWeb.PinController do
  use ClothespinWeb, :controller

  alias Clothespin.Pins
  alias Clothespin.Relay

  plug :require_membership when action in [:show, :invite, :bridge_token, :leave, :post_message]

  def create(conn, %{"title" => title}) do
    user = conn.assigns.current_user

    case Pins.create_room(user, title) do
      {:ok, room} ->
        conn
        |> put_flash(:info, "Pin created. Share the invite link with a teammate.")
        |> redirect(to: ~p"/pins/#{room.id}")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "A pin needs a 1–200 character title.")
        |> redirect(to: ~p"/")
    end
  end

  def show(conn, %{"id" => _id}) do
    conn
    |> assign_room_defaults()
    |> assign(:bridge_token, nil)
    |> assign(:bridge_command, nil)
    |> render(:room)
  end

  def invite(conn, %{"id" => _id}) do
    conn
    |> assign_room_defaults()
    |> assign(:bridge_token, nil)
    |> assign(:bridge_command, nil)
    |> put_flash(:info, "Invite link below. It expires in 7 days.")
    |> render(:room)
  end

  def bridge_token(conn, %{"id" => _id}) do
    room = conn.assigns.room
    user = conn.assigns.current_user
    token = Pins.bridge_token(user, room)

    conn
    |> assign_room_defaults()
    |> assign(:bridge_token, token)
    |> assign(:bridge_command, Pins.bridge_command(Pins.server_url(), token))
    |> render(:room)
  end

  def join(conn, %{"token" => token}) do
    user = conn.assigns.current_user

    if user do
      case Pins.verify_invite(token) do
        {:ok, room} ->
          conn
          |> assign(:room, room)
          |> assign(:token, token)
          |> assign(:already_member, Pins.member?(user, room))
          |> render(:join)

        {:error, :invalid_invite} ->
          conn
          |> put_flash(:error, "That invite link is invalid or has expired (links last 7 days).")
          |> redirect(to: ~p"/")
      end
    else
      conn
      |> put_session(:next, "/join/" <> token)
      |> redirect(to: ~p"/")
    end
  end

  def join_submit(conn, %{"token" => token}) do
    user = conn.assigns.current_user

    with {:ok, room} <- Pins.verify_invite(token),
         :ok <- Pins.ensure_member(user, room) do
      conn
      |> put_flash(:info, "You joined “#{room.title}”.")
      |> redirect(to: ~p"/pins/#{room.id}")
    else
      {:error, :invalid_invite} ->
        conn
        |> put_flash(:error, "That invite link is invalid or has expired (links last 7 days).")
        |> redirect(to: ~p"/")

      _ ->
        conn
        |> put_flash(:error, "Could not join this pin.")
        |> redirect(to: ~p"/")
    end
  end

  def leave(conn, %{"id" => _id}) do
    user = conn.assigns.current_user
    room = conn.assigns.room

    case Pins.leave_room(user, room) do
      :ok ->
        conn
        |> put_flash(:info, "You left the pin. Your bridge token no longer works.")
        |> redirect(to: ~p"/")

      {:error, :not_a_member} ->
        conn
        |> put_flash(:error, "You are not in that pin.")
        |> redirect(to: ~p"/")
    end
  end

  # POST /pins/:room_id/conversations/:cid/messages — HTTP fallback for the
  # channel chat; same Relay.record_message + broadcast as the socket path.
  def post_message(conn, %{"room_id" => room_id, "conversation_id" => cid} = params) do
    room = conn.assigns.room
    user = conn.assigns.current_user

    with %Relay.Conversation{} = conversation <- Relay.get_conversation(room.id, cid),
         {:ok, message, _duplicate} <-
           Relay.record_message(room, %{
             conversation: conversation,
             sender_key: "human:#{user.username}",
             sender_name: user.display_name,
             sender_site: nil,
             client_message_id: params["client_message_id"] || Ecto.UUID.generate(),
             body: params["body"] || ""
           }) do
      payload = Relay.message_payload(message, conversation)

      ClothespinWeb.Endpoint.broadcast!("room:#{room_id}", "message_new", payload)

      conn
      |> redirect(to: ~p"/pins/#{room_id}?cid=#{cid}")
    else
      nil ->
        conn
        |> put_flash(:error, "That conversation no longer exists.")
        |> redirect(to: ~p"/pins/#{room_id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not send that message (empty or duplicate ID).")
        |> redirect(to: ~p"/pins/#{room_id}?cid=#{cid}")
    end
  end

  defp require_membership(conn, _opts) do
    user = conn.assigns[:current_user]
    room = Pins.get_room(conn.path_params["id"] || conn.path_params["room_id"])

    if user && room && Pins.member?(user, room) do
      assign(conn, :room, room)
    else
      conn
      |> put_flash(:error, "That pin does not exist or you are not a member.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  defp assign_room_defaults(conn) do
    room = conn.assigns.room
    user = conn.assigns.current_user
    snapshot = Relay.snapshot(room)

    selected =
      case conn.query_params["cid"] do
        cid when is_binary(cid) and cid != "" ->
          Enum.find(snapshot.conversations, &(&1.id == cid)) || latest(snapshot.conversations)

        _ ->
          latest(snapshot.conversations)
      end

    messages =
      if selected,
        do: Enum.filter(snapshot.messages, &(&1.conversation_id == selected.id)),
        else: []

    conn
    |> assign(:members, Pins.list_members(room))
    |> assign(:invite_url, Pins.invite_url(room, user))
    |> assign(:conversations, snapshot.conversations)
    |> assign(:selected, selected)
    |> assign(:messages, messages)
    |> assign(:agents, snapshot.agents)
    |> assign(
      :user_socket_token,
      Phoenix.Token.sign(ClothespinWeb.Endpoint, "user_socket", %{
        user_id: user.id,
        room_id: room.id,
        name: user.username
      })
    )
    |> assign(:client_message_id, Ecto.UUID.generate())
  end

  defp latest([]), do: nil
  defp latest(conversations), do: List.last(conversations)
end
