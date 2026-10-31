defmodule Clothespin.SiteRegistry do
  @moduledoc """
  Tracks attached bridges per room: `%{room_id => %{site_name => pid}}`.

  Bridges register after `hello` and unregister on socket termination. Pure
  ETS owned by this GenServer — no extra dependency.
  """

  use GenServer

  @table :clothespin_site_registry

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers this process as the bridge for `site_name` in `room_id`."
  def register(room_id, site_name, pid) when is_binary(room_id) and is_binary(site_name) do
    GenServer.call(__MODULE__, {:register, room_id, site_name, pid})
  end

  @doc "Removes the site registration (leave/replace)."
  def unregister(room_id, site_name) do
    GenServer.call(__MODULE__, {:unregister, room_id, site_name})
  end

  @doc "Site names currently attached in a room."
  def sites(room_id) do
    case :ets.lookup(@table, {:sites, room_id}) do
      [{_, sites}] -> Map.keys(sites)
      [] -> []
    end
  end

  @doc "Bridge pids attached in a room (all sites)."
  def pids(room_id) do
    case :ets.lookup(@table, {:sites, room_id}) do
      [{_, sites}] -> Map.values(sites)
      [] -> []
    end
  end

  @doc "Pid for one site, if attached."
  def site_pid(room_id, site_name) do
    case :ets.lookup(@table, {:sites, room_id}) do
      [{_, sites}] -> sites[site_name]
      [] -> nil
    end
  end

  @doc "Bridge pids in the room for every site except `exclude_site` (nil = all)."
  def pids_except(room_id, exclude_site) do
    case :ets.lookup(@table, {:sites, room_id}) do
      [{_, sites}] ->
        for {site, pid} <- sites, site != exclude_site, do: pid

      [] ->
        []
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, room_id, site_name, pid}, _from, state) do
    key = {:sites, room_id}

    sites =
      case :ets.lookup(@table, key) do
        [{_, sites}] -> sites
        [] -> %{}
      end

    # Replace any stale pid for the same site (bridge reconnect).
    sites[site_name] && Process.monitor(pid)
    :ets.insert(@table, {key, Map.put(sites, site_name, pid)})
    Process.monitor(pid)
    {:reply, :ok, state}
  end

  def handle_call({:unregister, room_id, site_name}, _from, state) do
    key = {:sites, room_id}

    case :ets.lookup(@table, key) do
      [{_, sites}] ->
        sites = Map.delete(sites, site_name)

        :ets.insert(@table, {key, sites})

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Drop every registration held by this pid across rooms.
    :ets.tab2list(@table)
    |> Enum.each(fn {key, sites} ->
      case sites do
        %{} ->
          if pid in Map.values(sites) do
            cleaned = for {site, p} <- sites, p != pid, into: %{}, do: {site, p}
            :ets.insert(@table, {key, cleaned})
          end

        _ ->
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
