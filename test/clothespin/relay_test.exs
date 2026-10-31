defmodule Clothespin.RelayTest do
  use Clothespin.DataCase, async: true

  alias Clothespin.Accounts
  alias Clothespin.Pins
  alias Clothespin.Relay

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "relayuser",
        display_name: "Relay User",
        passphrase: "relay passphrase 123"
      })

    {:ok, room} = Pins.create_room(user, "relay room")
    %{room: room, user: user}
  end

  defp conv(room, site \\ "alpha", ref \\ "c-1", title \\ "Shared plan") do
    {:ok, conversation} =
      Relay.upsert_conversation(room, %{
        origin_site: site,
        origin_ref: ref,
        title: title,
        project_key: "proj",
        created_by: "agent:alpha:a-1"
      })

    conversation
  end

  describe "upsert_conversation/2" do
    test "same origin key returns the same conversation", %{room: room} do
      first = conv(room)
      second = conv(room)
      assert first.id == second.id
    end

    test "different origins are distinct; web-opened are always new", %{room: room} do
      a = conv(room, "alpha", "c-1")
      b = conv(room, "beta", "c-1")
      refute a.id == b.id

      {:ok, web1} = Relay.upsert_conversation(room, %{title: "web thread"})
      {:ok, web2} = Relay.upsert_conversation(room, %{title: "web thread"})
      refute web1.id == web2.id
      assert is_nil(web1.origin_site)
    end

    test "foreign conversations require origin_ref", %{room: room} do
      assert {:error, :origin_ref_required} =
               Relay.upsert_conversation(room, %{origin_site: "alpha", title: "x"})
    end
  end

  describe "record_message/2 idempotency" do
    test "duplicate send returns the same id with duplicate: true", %{room: room} do
      conversation = conv(room)

      attrs = %{
        conversation: conversation,
        sender_key: "agent:alpha:a-1",
        sender_name: "alpha:a-1",
        sender_site: "alpha",
        client_message_id: "cmid-1",
        body: "hello beta"
      }

      assert {:ok, m1, false} = Relay.record_message(room, attrs)
      assert {:ok, m2, true} = Relay.record_message(room, attrs)
      assert m1.id == m2.id
    end

    test "reused client_message_id with different body conflicts", %{room: room} do
      conversation = conv(room)

      base = %{
        conversation: conversation,
        sender_key: "agent:alpha:a-1",
        sender_name: "alpha:a-1",
        sender_site: "alpha",
        client_message_id: "cmid-2"
      }

      assert {:ok, _, false} = Relay.record_message(room, Map.put(base, :body, "one"))
      assert {:error, :client_message_id_conflict} =
               Relay.record_message(room, Map.put(base, :body, "two"))
    end

    test "different senders can use the same client_message_id", %{room: room} do
      conversation = conv(room)

      for sender <- ["agent:alpha:a-1", "agent:beta:b-1"] do
        assert {:ok, _, false} =
                 Relay.record_message(room, %{
                   conversation: conversation,
                   sender_key: sender,
                   sender_name: sender,
                   sender_site: String.replace(sender, ~r/^agent:|:.*/, "") |> then(fn _ -> String.split(sender, ":") |> Enum.at(1) end),
                   client_message_id: "same-cmid",
                   body: "from #{sender}"
                 })
      end
    end

    test "empty body and empty client_message_id are rejected", %{room: room} do
      conversation = conv(room)

      assert {:error, :invalid_body} =
               Relay.record_message(room, %{
                 conversation: conversation,
                 sender_key: "agent:alpha:a-1",
                 sender_name: "a",
                 sender_site: "alpha",
                 client_message_id: "x",
                 body: "   "
               })

      assert {:error, :invalid_client_message_id} =
               Relay.record_message(room, %{
                 conversation: conversation,
                 sender_key: "agent:alpha:a-1",
                 sender_name: "a",
                 sender_site: "alpha",
                 client_message_id: "",
                 body: "hi"
               })
    end
  end

  describe "route/1" do
    test "direct messages target the recipient site only", %{room: room} do
      conversation = conv(room)

      {:ok, message, false} =
        Relay.record_message(room, %{
          conversation: conversation,
          sender_key: "agent:alpha:a-1",
          sender_name: "a",
          sender_site: "alpha",
          recipient_site: "beta",
          recipient_agent_ref: "b-1",
          client_message_id: "r-1",
          body: "dm"
        })

      assert Relay.route(message) == %{direct_sites: ["beta"], broadcast: false}
    end

    test "broadcasts have no direct sites", %{room: room} do
      conversation = conv(room)

      {:ok, message, false} =
        Relay.record_message(room, %{
          conversation: conversation,
          sender_key: "agent:alpha:a-1",
          sender_name: "a",
          sender_site: "alpha",
          client_message_id: "r-2",
          body: "everyone"
        })

      assert Relay.route(message) == %{direct_sites: [], broadcast: true}
    end
  end

  describe "record_agent_event/2" do
    test "upserts by (room, site, agent_ref) and maps events", %{room: room} do
      base = %{site_name: "alpha", agent_ref: "a-1", external_id: "alpha-agent-1"}

      assert {:ok, %{state: "online"}} =
               Relay.record_agent_event(room, Map.put(base, :event, "online"))

      assert {:ok, %{state: "online", status_message: "building bridge"}} =
               Relay.record_agent_event(
                 room,
                 Map.merge(base, %{event: "online", status_message: "building bridge"})
               )

      assert {:ok, %{state: "stale"}} =
               Relay.record_agent_event(room, Map.put(base, :event, "stale"))

      assert {:ok, %{state: "offline", status_message: nil}} =
               Relay.record_agent_event(room, Map.put(base, :event, "offline"))
    end
  end

  describe "snapshot/2" do
    test "returns last messages ascending, agents, conversations", %{room: room} do
      conversation = conv(room)
      for i <- 1..3, do: Relay.record_message(room, message(room, conversation, "m-#{i}", "body #{i}"))
      Relay.record_agent_event(room, %{site_name: "alpha", agent_ref: "a-1", external_id: "x", event: "online"})

      snap = Relay.snapshot(room, 2)
      assert Enum.map(snap.messages, & &1.body) == ["body 2", "body 3"]
      assert length(snap.agents) == 1
      assert Enum.map(snap.conversations, & &1.title) == ["Shared plan"]
    end
  end

  describe "message_payload/2" do
    test "human and agent kinds resolve", %{room: room} do
      conversation = conv(room)

      {:ok, human_message, _} =
        Relay.record_message(room, %{
          conversation: conversation,
          sender_key: "human:alice",
          sender_name: "alice",
          client_message_id: "h-1",
          body: "hi agents"
        })

      payload = Relay.message_payload(human_message, conversation)
      assert payload.sender_kind == "human"
      assert is_nil(payload.sender_agent_ref)
      assert payload.conversation.title == "Shared plan"

      {:ok, agent_message, _} =
        Relay.record_message(room, %{
          conversation: conversation,
          sender_key: "agent:alpha:a-9",
          sender_name: "a-9",
          sender_site: "alpha",
          recipient_site: "beta",
          recipient_agent_ref: "b-2",
          client_message_id: "a-1",
          body: "dm"
        })

      payload = Relay.message_payload(agent_message, conversation)
      assert payload.sender_kind == "agent"
      assert payload.sender_agent_ref == "a-9"
      assert payload.recipient_site == "beta"
    end
  end

  defp message(room, conversation, cmid, body) do
    %{
      conversation: conversation,
      sender_key: "agent:alpha:a-1",
      sender_name: "a",
      sender_site: "alpha",
      client_message_id: cmid,
      body: body
    }
  end
end
