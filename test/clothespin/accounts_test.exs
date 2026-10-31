defmodule Clothespin.AccountsTest do
  use Clothespin.DataCase, async: true

  alias Clothespin.Accounts

  @valid %{
    username: "Alice-Tester",
    display_name: "Alice",
    passphrase: "correct horse battery staple"
  }

  test "create_user downcases the username and hashes the passphrase" do
    assert {:ok, user} = Accounts.create_user(@valid)
    assert user.username == "alice-tester"
    assert user.display_name == "Alice"
    assert String.starts_with?(user.password_hash, "$2")
    refute user.password_hash == @valid.passphrase
  end

  test "create_user rejects taken usernames with {:error, :taken}" do
    {:ok, _} = Accounts.create_user(@valid)
    assert {:error, :taken} = Accounts.create_user(@valid)
  end

  test "create_user validates shape" do
    assert {:error, %{errors: errors}} = Accounts.create_user(%{@valid | username: "ab"})
    assert errors[:username]
    assert {:error, %{errors: errors}} = Accounts.create_user(%{@valid | passphrase: "short"})
    assert errors[:passphrase]
    assert {:error, %{errors: errors}} = Accounts.create_user(%{@valid | username: "has space"})
    assert errors[:username]
  end

  test "authenticate verifies passphrase" do
    {:ok, user} = Accounts.create_user(@valid)
    assert {:ok, recovered} = Accounts.authenticate("ALICE-TESTER", @valid.passphrase)
    assert recovered.id == user.id
    assert {:error, :invalid} = Accounts.authenticate("alice-tester", "wrong passphrase!!")
    assert {:error, :invalid} = Accounts.authenticate("ghost", "whatever passphrase")
  end

  test "agent tokens round-trip for 90 days" do
    {:ok, user} = Accounts.create_user(@valid)
    token = Accounts.agent_token(user)
    assert {:ok, recovered} = Accounts.verify_agent_token(token)
    assert recovered.id == user.id
    assert {:error, :invalid_token} = Accounts.verify_agent_token("garbage")
  end
end
