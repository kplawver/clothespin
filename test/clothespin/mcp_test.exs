defmodule Clothespin.MCPTest do
  use Clothespin.DataCase, async: true

  alias Clothespin.{Accounts, MCP, Pins, Relay}

  setup do
    {:ok, state} = MCP.init([])
    %{state: state}
  end

  defp call(tool, args, state) do
    {:ok, result, _state} = MCP.handle_call_tool(tool, args, state)

    text = result.content |> List.first() |> Map.get(:text)
    Jason.decode!(text)
  end

  test "create_account, login, whoami round trip", %{state: state} do
    assert %{"username" => "mcpuser", "display_name" => "Mcp"} =
             call(
               "create_account",
               %{
                 "username" => "McpUser",
                 "display_name" => "Mcp",
                 "passphrase" => "mcp passphrase 123"
               },
               state
             )

    assert %{"error" => "username is already taken"} =
             call(
               "create_account",
               %{
                 "username" => "mcpuser",
                 "display_name" => "Mcp",
                 "passphrase" => "mcp passphrase 123"
               },
               state
             )

    assert %{"error" => error} =
             call(
               "create_account",
               %{"username" => "x", "display_name" => "X", "passphrase" => "short"},
               state
             )

    assert error =~ "username"

    assert %{"token" => token, "expires_in" => 7_776_000} =
             call(
               "login",
               %{"username" => "mcpuser", "passphrase" => "mcp passphrase 123"},
               state
             )

    assert %{"error" => "wrong username or passphrase"} =
             call("login", %{"username" => "mcpuser", "passphrase" => "nope nope nope"}, state)

    assert %{"username" => "mcpuser", "pins" => []} = call("whoami", %{"token" => token}, state)
  end

  test "pin_session, join_pin, pin_status, pin_stop lifecycle", %{state: state} do
    {:ok, alice} =
      Accounts.create_user(%{
        username: "alice",
        display_name: "Alice",
        passphrase: "alice passphrase 123"
      })

    {:ok, bob} =
      Accounts.create_user(%{
        username: "bob",
        display_name: "Bob",
        passphrase: "bob passphrase 1234"
      })

    alice_token = Accounts.agent_token(alice)
    bob_token = Accounts.agent_token(bob)

    assert %{"room_id" => room_id, "invite_url" => invite, "bridge_command" => command} =
             call(
               "pin_session",
               %{"token" => alice_token, "title" => "shared plan", "site_name" => "alpha"},
               state
             )

    assert command =~ "mix pin.connect"
    assert command =~ "--site alpha"
    assert invite =~ "/join/"

    assert %{"room_id" => ^room_id, "bridge_command" => joined_command} =
             call("join_pin", %{"token" => bob_token, "invite_url" => invite}, state)

    assert joined_command =~ "mix pin.connect"

    # Presence + counts show up in pin_status.
    room = Pins.get_room(room_id)
    {:ok, _} = Relay.upsert_conversation(room, %{title: "c", created_by: "human:alice"})

    assert %{"bridges" => [], "conversations" => 1, "messages" => 0, "agents" => []} =
             call("pin_status", %{"token" => alice_token, "room_id" => room_id}, state)

    assert %{"error" => "unknown pin"} =
             call(
               "pin_status",
               %{"token" => bob_token, "room_id" => "00000000-0000-0000-0000-000000000000"},
               state
             )

    assert %{"left" => true} =
             call("pin_stop", %{"token" => bob_token, "room_id" => room_id}, state)

    assert %{"error" => "you are not a member of that pin"} =
             call("pin_stop", %{"token" => bob_token, "room_id" => room_id}, state)

    assert %{"pins" => []} = call("whoami", %{"token" => bob_token}, state)

    # Owner leaving deletes the pin for everyone.
    assert %{"left" => true} =
             call("pin_stop", %{"token" => alice_token, "room_id" => room_id}, state)

    assert %{"pins" => []} = call("whoami", %{"token" => alice_token}, state)
  end

  test "bad token errors cleanly", %{state: state} do
    assert %{"error" => "invalid_token"} = call("whoami", %{"token" => "garbage"}, state)
  end
end
