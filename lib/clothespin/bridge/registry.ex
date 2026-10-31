defmodule Clothespin.Bridge.Registry do
  @moduledoc """
  Bridge-side bookkeeping: our harness on the local clothesline bus, the
  mirror agents we host for foreign pin participants, local agents we
  announce, and conversation mappings (pin conversation ⇄ local bus).

  One bridge per VM; registered under its own name. All lookups are
  synchronous calls — callers are the Link and Pump processes.
  """

  use GenServer

  alias Clothespin.Bridge.McpClient

  @pin_prefix "pin:"

  defstruct [
    :mcp_url,
    :site,
    :harness_id,
    :bridge_agent,
    mirrors: %{},
    mirror_by_agent_id: %{},
    local_agents: %{},
    local_by_external: %{},
    local_convs: %{},
    server_convs: %{},
    cursors: %{}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Reads

  def harness_id, do: GenServer.call(__MODULE__, :harness_id)
  def mcp_url, do: GenServer.call(__MODULE__, :mcp_url)
  def site, do: GenServer.call(__MODULE__, :site)
  def bridge_agent, do: GenServer.call(__MODULE__, :bridge_agent)
  def list_mirrors, do: GenServer.call(__MODULE__, :list_mirrors)
  def mirror_by_agent_id(agent_id), do: GenServer.call(__MODULE__, {:mirror_by_agent_id, agent_id})
  def local_agent(agent_id), do: GenServer.call(__MODULE__, {:local_agent, agent_id})
  def local_agent_by_external(external_id), do: GenServer.call(__MODULE__, {:local_agent_by_external, external_id})
  def refresh_locals, do: GenServer.call(__MODULE__, :refresh_locals)
  def local_agents, do: GenServer.call(__MODULE__, :local_agents)
  def local_conv_info(local_conv_id), do: GenServer.call(__MODULE__, {:local_conv_info, local_conv_id})
  def server_conv_local(server_conv_id), do: GenServer.call(__MODULE__, {:server_conv_local, server_conv_id})

  ## Writes

  def ensure_mirror(site, agent_ref, display_name),
    do: GenServer.call(__MODULE__, {:ensure_mirror, site, agent_ref, display_name})

  def put_local_agents(agents), do: GenServer.call(__MODULE__, {:put_local_agents, agents})
  def put_server_conv(server_conv_id, local_conv_id), do: GenServer.call(__MODULE__, {:put_server_conv, server_conv_id, local_conv_id})
  def put_local_conv(local_conv_id, info), do: GenServer.call(__MODULE__, {:put_local_conv, local_conv_id, info})
  def put_cursor(agent_id, after_id), do: GenServer.call(__MODULE__, {:put_cursor, agent_id, after_id})

  ## GenServer

  @impl true
  def init(opts) do
    mcp_url = Keyword.fetch!(opts, :mcp_url)
    site = Keyword.fetch!(opts, :site)

    case McpClient.tool(mcp_url, "register_harness", %{
           "installation_key" => "clothespin-bridge:#{site}",
           "name" => "pin bridge #{site}"
         }) do
      {:ok, %{"harness_id" => harness_id}} ->
        state = %__MODULE__{mcp_url: mcp_url, site: site, harness_id: harness_id}
        # A stable bridge agent on our own bus: it stays online and receives
        # every local broadcast, so outbound forwarding works even when no
        # foreign mirror shares the conversation yet.
        case ensure_bridge_agent(state) do
          {:ok, bridge_agent} ->
            # Seed local agents so the first hello can announce them. A failed
            # seed is non-fatal: the pump refreshes on first unknown sender and
            # the 30s announce diff retries.
            state = %{state | bridge_agent: bridge_agent}

            {:ok, elem(refresh_local_agents(state), 1)}

          {:error, reason} ->
            {:stop, {:bridge_agent_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:bus_unreachable, reason}}
    end
  end

  @impl true
  def handle_call(:harness_id, _from, state), do: {:reply, state.harness_id, state}
  def handle_call(:mcp_url, _from, state), do: {:reply, state.mcp_url, state}
  def handle_call(:site, _from, state), do: {:reply, state.site, state}
  def handle_call(:bridge_agent, _from, state), do: {:reply, state.bridge_agent, state}
  def handle_call(:list_mirrors, _from, state), do: {:reply, Map.values(state.mirrors), state}

  def handle_call({:mirror_by_agent_id, agent_id}, _from, state) do
    case Map.fetch(state.mirror_by_agent_id, agent_id) do
      {:ok, agent_key} -> {:reply, Map.fetch!(state.mirrors, agent_key), state}
      :error -> {:reply, nil, state}
    end
  end

  def handle_call({:local_agent, agent_id}, _from, state),
    do: {:reply, Map.get(state.local_agents, agent_id), state}

  def handle_call({:local_agent_by_external, external_id}, _from, state),
    do: {:reply, Map.get(state.local_by_external, external_id), state}

  def handle_call(:local_agents, _from, state), do: {:reply, Map.values(state.local_agents), state}

  def handle_call(:refresh_locals, _from, state) do
    case refresh_local_agents(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} -> {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:local_conv_info, local_conv_id}, _from, state) do
    case Map.fetch(state.local_convs, local_conv_id) do
      {:ok, info} ->
        {:reply, info, state}

      :error ->
        case McpClient.tool(state.mcp_url, "get_conversation", %{"conversation_id" => local_conv_id}) do
          {:ok, %{"conversation" => conv}} when is_map(conv) ->
            info = %{title: conv["title"], project_key: conv["project_key"]}
            {:reply, info, put_local_conv(state, local_conv_id, info)}

          _ ->
            {:reply, %{title: "bridged conversation", project_key: nil}, state}
        end
    end
  end

  def handle_call({:server_conv_local, server_conv_id}, _from, state),
    do: {:reply, Map.get(state.server_convs, server_conv_id), state}

  def handle_call({:ensure_mirror, site, agent_ref, display_name}, _from, state)
      when is_binary(agent_ref) and agent_ref != "" do
    agent_key = "#{site}:#{agent_ref}"

    case Map.fetch(state.mirrors, agent_key) do
      {:ok, mirror} ->
        {:reply, {:ok, mirror}, state}

      :error ->
        external_id = mirror_external_id(site, agent_ref)

        with {:ok, %{"agent_id" => agent_id}} <-
               McpClient.tool(state.mcp_url, "register_agent", %{
                 "harness_id" => state.harness_id,
                 "external_id" => external_id,
                 "name" => display_name || external_id
               }),
             {:ok, _} <-
               McpClient.tool(state.mcp_url, "agent_online", %{
                 "harness_id" => state.harness_id,
                 "agent_id" => agent_id
               }) do
          mirror = %{
            agent_key: agent_key,
            site: site,
            agent_ref: agent_ref,
            external_id: external_id,
            agent_id: agent_id,
            display_name: display_name || external_id
          }

          state =
            state
            |> put_in([Access.key(:mirrors), agent_key], mirror)
            |> put_in([Access.key(:mirror_by_agent_id), agent_id], agent_key)

          {:reply, {:ok, mirror}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:ensure_mirror, _site, _agent_ref, _display}, _from, state),
    do: {:reply, {:error, :bad_agent_ref}, state}

  def handle_call({:put_local_agents, agents}, _from, state) do
    local_agents = Map.new(agents, fn a -> {a["id"], a} end)
    local_by_external = Map.new(agents, fn a -> {a["external_id"], a["id"]} end)

    {:reply, :ok,
     %{state | local_agents: local_agents, local_by_external: local_by_external}}
  end

  def handle_call({:put_server_conv, server_conv_id, local_conv_id}, _from, state),
    do: {:reply, :ok, put_in(state, [Access.key(:server_convs), server_conv_id], local_conv_id)}

  def handle_call({:put_local_conv, local_conv_id, info}, _from, state),
    do: {:reply, :ok, put_local_conv(state, local_conv_id, info)}

  def handle_call({:put_cursor, agent_id, after_id}, _from, state),
    do: {:reply, :ok, put_in(state, [Access.key(:cursors), agent_id], after_id)}

  ## Helpers

  defp mirror_external_id(site, agent_ref) do
    ref8 = String.slice(agent_ref, 0, 8)
    "#{@pin_prefix}#{site}:#{ref8}"
  end

  defp put_local_conv(state, local_conv_id, info),
    do: put_in(state, [Access.key(:local_convs), local_conv_id], info)

  # Local agents = rows under other harnesses whose external_id is not a pin
  # mirror (ours or another bridge's on the same bus).
  # Returns {:ok, state} | {:error, :unavailable} so callers can retry on
  # transient bus errors instead of acting on a stale cache.
  defp refresh_local_agents(state) do
    case McpClient.tool(state.mcp_url, "list_agents", %{"include_inactive" => true}) do
      {:ok, %{"agents" => agents}} ->
        locals =
          Enum.filter(agents, fn a ->
            a["harness_id"] != state.harness_id and
              is_binary(a["external_id"]) and
              not String.starts_with?(a["external_id"], @pin_prefix)
          end)

        {:ok,
         %{
           state
           | local_agents: Map.new(locals, &{&1["id"], &1}),
             local_by_external: Map.new(locals, &{&1["external_id"], &1["id"]})
         }}

      _ ->
        {:error, :unavailable}
    end
  end

  defp ensure_bridge_agent(state) do
    external_id = "#{@pin_prefix}bridge:#{state.site}"

    with {:ok, %{"agent_id" => agent_id}} <-
           McpClient.tool(state.mcp_url, "register_agent", %{
             "harness_id" => state.harness_id,
             "external_id" => external_id,
             "name" => "pin bridge #{state.site}"
           }),
         {:ok, _} <-
           McpClient.tool(state.mcp_url, "agent_online", %{
             "harness_id" => state.harness_id,
             "agent_id" => agent_id
           }) do
      {:ok, %{agent_id: agent_id, external_id: external_id}}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
