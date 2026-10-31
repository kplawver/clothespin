defmodule ClothespinWeb.SessionController do
  use ClothespinWeb, :controller

  alias Clothespin.Accounts
  alias ClothespinWeb.UserAuth

  def signup(conn, %{"user" => params}) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        conn
        |> UserAuth.login(user)
        |> put_flash(:info, "Welcome, #{user.display_name}! Your account is ready.")
        |> redirect(to: next_path(conn, "/"))

      {:error, :taken} ->
        conn
        |> put_flash(:error, "That username is already taken.")
        |> redirect(to: ~p"/")

      {:error, changeset} ->
        errors =
          changeset.errors
          |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
          |> Enum.join("; ")

        conn
        |> put_flash(:error, "Signup failed — #{errors}")
        |> redirect(to: ~p"/")
    end
  end

  def login(conn, %{"username" => username, "passphrase" => passphrase}) do
    case Accounts.authenticate(username, passphrase) do
      {:ok, user} ->
        conn
        |> UserAuth.login(user)
        |> put_flash(:info, "Welcome back, #{user.display_name}.")
        |> redirect(to: next_path(conn, "/"))

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "Wrong username or passphrase.")
        |> redirect(to: ~p"/")
    end
  end

  def logout(conn, _params) do
    conn
    |> UserAuth.logout()
    |> put_flash(:info, "Logged out.")
    |> redirect(to: ~p"/")
  end

  defp next_path(conn, default) do
    case conn.params["next"] do
      path when is_binary(path) and path != "" ->
        if String.starts_with?(path, "/"), do: path, else: default

      _ ->
        case get_session(conn, :next) do
          path when is_binary(path) and path != "" -> path
          _ -> default
        end
    end
  end
end
