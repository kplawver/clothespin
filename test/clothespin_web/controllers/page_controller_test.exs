defmodule ClothespinWeb.PageControllerTest do
  use ClothespinWeb.ConnCase, async: true

  test "GET / logged out shows login and signup forms" do
    conn = get(build_conn(), "/")
    html = html_response(conn, 200)
    assert html =~ "Log in"
    assert html =~ "Create an account"
  end

  test "GET / logged in shows the pin dashboard" do
    {:ok, user} =
      Clothespin.Accounts.create_user(%{
        username: "pageuser",
        display_name: "Page User",
        passphrase: "a decent passphrase"
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_session(:user_id, user.id)
      |> get("/")

    html = html_response(conn, 200)
    assert html =~ "Your pins"
    assert html =~ "New pin"
  end
end
