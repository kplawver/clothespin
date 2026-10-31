defmodule ClothespinWeb.UserSocket do
  use Phoenix.Socket

  @max_age 14 * 24 * 3600

  channel "room:*", ClothespinWeb.RoomChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, %{user_id: user_id, room_id: room_id, name: name}} <-
           Phoenix.Token.verify(ClothespinWeb.Endpoint, "user_socket", token, max_age: @max_age),
         %Clothespin.Accounts.User{} = user <- Clothespin.Accounts.get_user(user_id),
         %Clothespin.Pins.Room{} = room <- Clothespin.Pins.get_room(room_id),
         true <- Clothespin.Pins.member?(user, room) do
      {:ok, assign(socket, user_id: user_id, room_id: room_id, user_name: name)}
    else
      _ -> :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(socket), do: "user:#{socket.assigns.user_id}"
end
