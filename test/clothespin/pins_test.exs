defmodule Clothespin.PinsTest do
  use Clothespin.DataCase, async: true

  alias Clothespin.Accounts
  alias Clothespin.Pins

  defp user(name) do
    {:ok, u} =
      Accounts.create_user(%{
        username: name,
        display_name: String.capitalize(name),
        passphrase: "passphrase #{name} 123"
      })

    u
  end

  test "create_room adds the owner membership" do
    alice = user("alice")
    assert {:ok, room} = Pins.create_room(alice, "shared plan")
    assert Pins.member?(alice, room)
    assert [{member, "owner"}] = Pins.list_members(room)
    assert member.id == alice.id
  end

  test "invite tokens verify for 7 days and die with the room" do
    alice = user("alice")
    bob = user("bob")
    {:ok, room} = Pins.create_room(alice, "shared plan")

    token = Pins.invite_token(room, alice)
    assert {:ok, invite_room} = Pins.verify_invite(token)
    assert invite_room.id == room.id

    :ok = Pins.leave_room(alice, room)
    assert {:error, :invalid_invite} = Pins.verify_invite(token)
  end

  test "ensure_member is idempotent; member gating and listing work" do
    alice = user("alice")
    bob = user("bob")
    {:ok, room} = Pins.create_room(alice, "shared plan")
    assert :ok = Pins.ensure_member(bob, room)
    assert :ok = Pins.ensure_member(bob, room)
    assert Pins.member?(bob, room)
    assert [%Clothespin.Pins.Room{title: "shared plan"} | _] = Pins.list_rooms(bob)
    assert length(Pins.list_members(room)) == 2
  end

  test "non-owner leaving keeps the room; owner leaving deletes it and memberships" do
    alice = user("alice")
    bob = user("bob")
    {:ok, room} = Pins.create_room(alice, "shared plan")
    :ok = Pins.ensure_member(bob, room)

    assert :ok = Pins.leave_room(bob, room)
    refute Pins.member?(bob, room)
    assert Pins.get_room(room.id)

    assert :ok = Pins.leave_room(alice, room)
    refute Pins.get_room(room.id)
    refute Pins.member?(bob, room)
  end

  test "bridge tokens: valid while a member, revoked on leave" do
    alice = user("alice")
    bob = user("bob")
    {:ok, room} = Pins.create_room(alice, "shared plan")

    bob_token = Pins.bridge_token(bob, room)
    assert {:error, :invalid_bridge_token} = Pins.verify_bridge(bob_token)

    :ok = Pins.ensure_member(bob, room)
    assert {:ok, bridge_user, bridge_room} = Pins.verify_bridge(bob_token)
    assert bridge_user.id == bob.id
    assert bridge_room.id == room.id

    :ok = Pins.leave_room(bob, room)
    assert {:error, :invalid_bridge_token} = Pins.verify_bridge(bob_token)
  end

  test "bridge_command is the single source of truth" do
    cmd = Pins.bridge_command("http://pin.example", "TOK", "alpha")

    assert cmd ==
             "mix pin.connect --server http://pin.example --bridge-token TOK " <>
               "--clothesline http://127.0.0.1:19004/mcp --site alpha"
  end
end
