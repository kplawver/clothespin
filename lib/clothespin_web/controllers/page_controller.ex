defmodule ClothespinWeb.PageController do
  use ClothespinWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
