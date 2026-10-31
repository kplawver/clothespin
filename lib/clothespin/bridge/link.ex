defmodule Clothespin.Bridge.Link do
  @moduledoc """
  WebSocket link to the pin (`<server>/bridge?bridge_token=…`).

  Speaks the BridgeSock frame protocol: requests carry `{op, ref, …}` and
  get `{ok, ref, payload}` back; server pushes carry `{op, payload}`.
  Reconnects with 1s→30s backoff. On (re)connect it says hello with the
  current local-agent announce list and replays the snapshot into the local
  bus before any live push is processed, so ordering holds.
  """

  use GenServer

  alias Clothespin.Bridge.{Injector, Registry}

  @ping_every 30_000
  @call_timeout 10_000

  defstruct [
    :server,
    :token,
    :site,
    :gun_pid,
    :stream,
    connected?: false,
    ref: 0,
    pending: %{},
    backoff: 1_000
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send an op and wait for its reply payload."
  def call(op, frame \\ %{}, timeout \\ @call_timeout) do
    GenServer.call(__MODULE__, {:call, op, frame}, timeout + 500)
  end

  def connected?, do: GenServer.call(__MODULE__, :connected?)

  ## GenServer

  @impl true
  def init(opts) do
    state = %__MODULE__{
      server: Keyword.fetch!(opts, :server),
      token: Keyword.fetch!(opts, :token),
      site: Keyword.fetch!(opts, :site)
    }

    :timer.send_interval(@ping_every, :ping)
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.connected?, state}

  def handle_call({:call, _op, _frame}, _from, %{connected?: false} = state),
    do: {:reply, {:error, :disconnected}, state}

  def handle_call({:call, op, frame}, from, state) do
    ref = state.ref + 1
    frame = Map.merge(frame, %{"op" => op, "ref" => ref})

    # ws_send can raise if the socket died between the connected? check and
    # now; that crashes this GenServer and it reconnects — callers time out
    # via the supervisor restart, so no reply leak.
    ws_send(state, frame)
    {:noreply, %{state | ref: ref, pending: Map.put(state.pending, ref, from)}}
  end

  @impl true
  def handle_info(:connect, state) do
    case open_ws(state) do
      {:ok, gun_pid} ->
        {:noreply, %{state | gun_pid: gun_pid}}

      :error ->
        schedule_reconnect(state)
    end
  end

  def handle_info({:gun_up, pid, _proto}, %{gun_pid: pid} = state) do
    query = URI.encode_query(bridge_token: state.token)
    path = "/bridge?#{query}"
    stream = :gun.ws_upgrade(pid, path)
    {:noreply, %{state | stream: stream}}
  end

  def handle_info({:gun_upgrade, pid, _stream, [<<"websocket">>], _}, %{gun_pid: pid} = state) do
    announce =
      Enum.map(Registry.local_agents(), fn agent ->
        %{
          "agent_ref" => agent["external_id"],
          "external_id" => agent["external_id"],
          "event" => agent["status"] == "offline" && "offline" || "online",
          "status_message" => agent["status_message"]
        }
      end)

    hello = Map.merge(%{"op" => "hello", "ref" => next_ref(state)}, %{
      "site_name" => state.site,
      "announce" => announce
    })

    case ws_request(state, hello) do
      {:ok, %{"snapshot" => snapshot}} ->
        Injector.reconcile_snapshot(snapshot)
        state = %{state | connected?: true, backoff: 1_000, ref: state.ref + 1}
        {:noreply, state}

      {:error, :hello_rejected} ->
        # Bad site name or room state — retrying won't help; back off hard.
        state = %{state | connected?: false}
        Process.send_after(self(), :connect, 30_000)
        {:noreply, %{state | gun_pid: nil}}

      {:error, _reason} ->
        schedule_reconnect(%{state | gun_pid: nil})
    end
  end

  def handle_info({:gun_ws, pid, _stream, {:text, text}}, %{gun_pid: pid} = state) do
    frame = Jason.decode!(text)

    case frame do
      %{"op" => op, "payload" => payload} ->
        handle_push(op, payload)
        {:noreply, state}

      %{"ref" => ref} = reply when is_integer(ref) ->
        case Map.pop(state.pending, ref) do
          {nil, _} ->
            {:noreply, state}

          {from, pending} ->
            GenServer.reply(from, unwrap_reply(reply))
            {:noreply, %{state | pending: pending}}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:gun_ws, pid, _stream, :close}, %{gun_pid: pid} = state),
    do: handle_down(state)

  def handle_info({:gun_down, pid, _proto, _reason, _killed}, %{gun_pid: pid} = state),
    do: handle_down(state)

  def handle_info(:ping, %{connected?: true} = state) do
    case ws_request(state, %{"op" => "ping", "ref" => next_ref(state)}) do
      {:ok, _} -> {:noreply, state}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  # Frames parked by await_ref while it awaited its own reply: re-dispatch
  # through the normal clauses so pushes/replies are never lost.
  def handle_info({:link_requeue, msg}, state), do: handle_info(msg, state)

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp handle_down(state) do
    Enum.each(state.pending, fn {_ref, from} -> GenServer.reply(from, {:error, :disconnected}) end)
    schedule_reconnect(%{state | connected?: false, gun_pid: nil, pending: %{}})
  end

  defp handle_push("message_new", payload), do: Injector.inject_message(payload)

  defp handle_push("agent_event", payload), do: Injector.inject_agent_event(payload)
  defp handle_push(_op, _payload), do: :ok

  defp schedule_reconnect(state) do
    delay = state.backoff
    Process.send_after(self(), :connect, delay)
    {:noreply, %{state | backoff: min(delay * 2, 30_000)}}
  end

  defp open_ws(state) do
    uri = URI.parse(state.server)
    port = uri.port || (uri.scheme == "https" && 443) || 80

    opts =
      %{protocols: [:http], http_opts: %{version: :"HTTP/1.1"}}
      |> maybe_tls(uri.scheme)

    case :gun.open(to_charlist(uri.host), port, opts) do
      {:ok, pid} ->
        :gun.set_owner(pid, self())
        {:ok, pid}

      _ ->
        :error
    end
  end

  defp maybe_tls(opts, "https"), do: Map.put(opts, :transport, :tls)
  defp maybe_tls(opts, _), do: opts

  defp next_ref(state), do: state.ref + 1

  defp ws_send(state, frame) do
    :ok = :gun.ws_send(state.gun_pid, state.stream, {:text, Jason.encode!(frame)})
    {:ok, :sent}
  end

  # Send a frame and await its reply inline (used for hello/ping during
  # handle_info, where we can't use handle_call).
  defp ws_request(state, frame) do
    ref = frame["ref"]

    with {:ok, _} <- ws_send(state, frame) do
      await_ref(ref, state.stream, @call_timeout)
    end
  end

  defp await_ref(_ref, _stream, deadline_left) when deadline_left <= 0, do: {:error, :timeout}

  # Awaits one reply ref. Frames that aren't the awaited reply (server pushes,
  # replies to other refs) are re-sent to this process so the regular
  # handle_info clauses process them — never discarded.
  defp await_ref(ref, stream, deadline_left) do
    t0 = System.monotonic_time(:millisecond)

    receive do
      {:gun_ws, pid, ^stream, {:text, text}} ->
        case Jason.decode!(text) do
          %{"ref" => ^ref} = reply ->
            unwrap_reply(reply)

          _other_frame ->
            # A push or another ref's reply: hand it to handle_info (wrapped
            # so this receive can't re-match it) and keep waiting.
            send(self(), {:link_requeue, {:gun_ws, pid, stream, {:text, text}}})
            await_ref(ref, stream, deadline_left - (System.monotonic_time(:millisecond) - t0))
        end

      {:gun_ws, _pid, ^stream, :close} ->
        send(self(), {:link_requeue, {:gun_ws, self(), stream, :close}})
        {:error, :link_closed}

      {:gun_down, pid, proto, reason, killed} ->
        send(self(), {:link_requeue, {:gun_down, pid, proto, reason, killed}})
        {:error, :link_down}
    after
      min(deadline_left, 1_000) ->
        if deadline_left <= 1_000 do
          {:error, :timeout}
        else
          await_ref(ref, stream, deadline_left - 1_000)
        end
    end
  end

  defp unwrap_reply(%{"ok" => true, "payload" => payload}), do: {:ok, payload}
  defp unwrap_reply(%{"ok" => true}), do: {:ok, %{}}
  defp unwrap_reply(%{"ok" => false, "ref" => ref}) when ref == 1, do: {:error, :hello_rejected}
  defp unwrap_reply(%{"ok" => false, "error" => error}), do: {:error, error}
  defp unwrap_reply(_), do: {:error, :bad_reply}
end
