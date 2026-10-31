defmodule ClothespinWeb.UserAuth do
  @moduledoc """
  Session plugs and helpers: cookie holds `user_id`, signed by the endpoint.
  """

  import Phoenix.Controller
  import Plug.Conn
  alias Clothespin.Accounts
  @doc "Makes `conn.assigns.current_user` available (nil when logged out)."
  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_user, user)
  end

  # Module-plug surface so the router can use `plug ClothespinWeb.UserAuth`.
  def init(opts), do: opts

  def call(conn, _opts), do: fetch_current_user(conn, nil)

  def require_login(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Please log in first.")
      |> redirect(to: "/?next=" <> URI.encode_www_form(current_path(conn)))
      |> halt()
    end
  end

  @doc "Puts the user in the session and renews the session id."
  def login(conn, user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
  end

  @doc "Drops the user from the session and renews the session id."
  def logout(conn) do
    renew_session(conn)
    |> delete_session(:user_id)
  end

  defp renew_session(conn) do
    configure_session(conn, renew: true)
    |> clear_session()
  end
end
