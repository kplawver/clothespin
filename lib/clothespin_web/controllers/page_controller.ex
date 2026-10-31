defmodule ClothespinWeb.PageController do
  use ClothespinWeb, :controller

  alias Clothespin.Pins

  def home(conn, _params) do
    if user = conn.assigns[:current_user] do
      conn
      |> assign(:rooms, Pins.list_rooms(user))
      |> render(:dashboard)
    else
      conn
      |> put_session(:next, conn.params["next"])
      |> render(:home)
    end
  end
end
