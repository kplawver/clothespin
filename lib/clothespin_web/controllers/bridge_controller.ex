defmodule ClothespinWeb.BridgeController do
  use ClothespinWeb, :controller

  alias Clothespin.Pins

  def upgrade(conn, _params) do
    case Pins.verify_bridge(conn.query_params["bridge_token"] || "") do
      {:ok, _user, room} ->
        WebSockAdapter.upgrade(conn, ClothespinWeb.BridgeSock, %{room: room}, [])

      {:error, :invalid_bridge_token} ->
        send_resp(conn, 401, Jason.encode!(%{error: "invalid bridge token"}))
    end
  end
end
