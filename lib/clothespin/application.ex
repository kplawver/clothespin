defmodule Clothespin.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClothespinWeb.Telemetry,
      Clothespin.Repo,
      {DNSCluster, query: Application.get_env(:clothespin, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Clothespin.PubSub},
      ClothespinWeb.Presence,
      # Start the bridge site registry (step 5) before the endpoint.
      Clothespin.SiteRegistry,
      # Start to serve requests, typically the last entry
      ClothespinWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Clothespin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClothespinWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
