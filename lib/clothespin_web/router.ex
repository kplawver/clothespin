defmodule ClothespinWeb.Router do
  use ClothespinWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClothespinWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ClothespinWeb.UserAuth
  end

  scope "/", ClothespinWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/signup", SessionController, :signup
    post "/login", SessionController, :login
    delete "/logout", SessionController, :logout

    post "/pins", PinController, :create
    get "/pins/:id", PinController, :show
    post "/pins/:id/invite", PinController, :invite
    post "/pins/:id/bridge-token", PinController, :bridge_token
    delete "/pins/:id/leave", PinController, :leave
    post "/pins/:room_id/conversations/:conversation_id/messages", PinController, :post_message

    get "/join/:token", PinController, :join
    post "/join/:token", PinController, :join_submit
    get "/bridge", BridgeController, :upgrade
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClothespinWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:clothespin, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ClothespinWeb.Telemetry
    end
  end
end
