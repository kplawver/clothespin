defmodule ClothespinWeb.BridgeSockTest do
  # In-process WebSock callback tests: no real socket, we drive handle_in and
  # inspect state + registry side effects.
  use Clothespin.DataCase, async: true

  alias Clothespin.{Accounts, Pins, Relay, SiteRegistry}
  alias ClothespinWeb.BridgeSock

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "bsockuser",
        display_name: "B",
        passphrase: "bsock passphrase 12"
      })

    {:ok, room} = Pins.create_room(user, "bsock room")
    # SiteRegistry runs under the app supervisor; isolate by room id.
    state = BridgeSock.init(%{room: room}) |> elem(1)
    %{room: room, state: state}
  end

  defp frame(op, ref, extra) do
    {Jason.encode!(Map.merge(%{"op" => op, "ref" => ref}, extra)), :text}
  end

  test "hello registers the site and returns a snapshot", %{room: room, state: state} do
    assert {:reply, :ok, [{:text, text}], _} =
             BridgeSock.handle_in(frame("hello", 1, %{"site_name" => "alpha"}), state)

    assert %{
             "ok" => true,
             "ref" => 1,
             "payload" => %{"site_id" => "alpha", "snapshot" => snapshot}
           } =
             Jason.decode!(text)

    assert snapshot["messages"] == []
    assert SiteRegistry.sites(room.id) == ["alpha"]
  end

  test "hello rejects malformed site names", %{state: state} do
    assert {:push, [{:text, text}], _} =
             BridgeSock.handle_in(frame("hello", 2, %{"site_name" => "Not A Site!"}), state)

    assert %{"ok" => false, "error" => error} = Jason.decode!(text)
    assert error =~ "site_name must match"
  end

  test "message before hello is refused", %{state: state} do
    assert {:push, [{:text, text}], _} =
             BridgeSock.handle_in(frame("message", 3, %{}), state)

    assert %{"ok" => false, "error" => "say hello first"} = Jason.decode!(text)
  end

  test "message records idempotently and reports duplicates", %{room: room, state: state} do
    state =
      case BridgeSock.handle_in(frame("hello", 1, %{"site_name" => "alpha"}), state) do
        {:reply, :ok, _msgs, s} -> s
      end

    msg = %{
      "conversation" => %{"origin_site" => "alpha", "origin_ref" => "conv-1", "title" => "T"},
      "client_message_id" => "cm-a",
      "sender_agent_ref" => "agent-1",
      "sender_external_id" => "alpha agent",
      "body" => "hello beta"
    }

    assert {:reply, :ok, [{:text, t1}], _} =
             BridgeSock.handle_in(frame("message", 10, msg), state)

    assert %{"ok" => true, "payload" => %{"message_id" => id, "duplicate" => false}} =
             Jason.decode!(t1)

    assert {:reply, :ok, [{:text, t2}], _} =
             BridgeSock.handle_in(frame("message", 11, msg), state)

    assert %{"payload" => %{"message_id" => ^id, "duplicate" => true}} = Jason.decode!(t2)

    assert [%{body: "hello beta"}] = Relay.snapshot(room).messages
  end

  test "duplicate message pushes nothing to other bridges", %{room: room, state: state} do
    state =
      case BridgeSock.handle_in(frame("hello", 1, %{"site_name" => "alpha"}), state) do
        {:reply, :ok, _msgs, s} -> s
      end

    # This test process pretends to be the "beta" bridge socket: pushes
    # targeted at beta land in our mailbox.
    :ok = SiteRegistry.register(room.id, "beta", self())

    msg = %{
      "conversation" => %{"origin_site" => "alpha", "origin_ref" => "conv-dup", "title" => "T"},
      "client_message_id" => "cm-dup",
      "sender_agent_ref" => "agent-1",
      "sender_external_id" => "alpha agent",
      "body" => "dup body"
    }

    {:reply, :ok, _msgs, _s1} = BridgeSock.handle_in(frame("message", 10, msg), state)
    assert_receive {:push, json}
    assert json =~ "dup body"

    # Replayed frame: recorded as a duplicate, but nothing is re-pushed.
    {:reply, :ok, _msgs, _s2} = BridgeSock.handle_in(frame("message", 11, msg), state)
    refute_receive {:push, _json}, 200
  end


  test "agent_event upserts presence and echoes to other bridges", %{room: room, state: state} do
    state =
      case BridgeSock.handle_in(frame("hello", 1, %{"site_name" => "alpha"}), state) do
        {:reply, :ok, _msgs, s} -> s
      end

    event = %{
      "agent_ref" => "agent-2",
      "external_id" => "alpha agent 2",
      "event" => "online",
      "status_message" => "planning"
    }

    assert {:reply, :ok, [{:text, t}], _} =
             BridgeSock.handle_in(frame("agent_event", 20, event), state)

    assert %{"ok" => true} = Jason.decode!(t)

    assert [%{state: "online", status_message: "planning"}] = Relay.list_agents(room)
  end
end
