defmodule Clothespin.Bridge do
  @moduledoc """
  The bridge daemon supervision tree: Registry (bus identity + mappings),
  Link (pin WebSocket), Pump (poll/announce/heartbeat).

  One-for-all: Registry holds the shared identity; if it dies the Link and
  Pump have stale state and must restart with it.
  """

  use Supervisor

  alias Clothespin.Bridge

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = %{
      server: Keyword.fetch!(opts, :server),
      token: Keyword.fetch!(opts, :token),
      mcp_url: Keyword.fetch!(opts, :mcp_url),
      site: Keyword.fetch!(opts, :site),
      poll_ms: Keyword.get(opts, :poll_ms, 2_000)
    }

    children = [
      {Bridge.Registry, mcp_url: config.mcp_url, site: config.site},
      {Bridge.Link, server: config.server, token: config.token, site: config.site},
      {Bridge.Pump, poll_ms: config.poll_ms}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
