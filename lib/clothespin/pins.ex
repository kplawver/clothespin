defmodule Clothespin.Pins do
  @moduledoc """
  Pins: rooms, memberships, invite links, and bridge tokens.

  A pin (room) is the shared space. Membership gates everything; invites and
  bridge tokens are `Phoenix.Token` bearer values — attribution, not proof.
  """

  import Ecto.Query
  alias Clothespin.Accounts.User
  alias Clothespin.Pins.{Membership, Room}
  alias Clothespin.Repo

  @invite_max_age 7 * 24 * 3600

  ## Rooms and memberships

  def get_room(id) when is_binary(id), do: Repo.get(Room, id)
  def get_room(_), do: nil

  @doc "Creates a room and the owner membership in one transaction."
  def create_room(%User{id: user_id}, title) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:room, Room.changeset(%Room{}, %{title: title, owner_id: user_id}))
    |> Ecto.Multi.insert(:membership, fn %{room: room} ->
      %Membership{}
      |> Ecto.Changeset.change(user_id: user_id, room_id: room.id, role: "owner")
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{room: room}} -> {:ok, room}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc "Idempotently adds a user to a room."
  def ensure_member(%User{id: user_id}, %Room{id: room_id}) do
    %Membership{}
    |> Ecto.Changeset.change(user_id: user_id, room_id: room_id, role: "member")
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :room_id])
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def member?(%User{id: user_id}, %Room{id: room_id}) do
    Repo.exists?(from m in Membership, where: m.user_id == ^user_id and m.room_id == ^room_id)
  end

  @doc "Rooms the user belongs to, newest first."
  def list_rooms(%User{id: user_id}) do
    Repo.all(
      from(r in Room,
        join: m in Membership,
        on: m.room_id == r.id and m.user_id == ^user_id,
        order_by: [desc: r.inserted_at]
      )
    )
  end

  @doc "Leaves a room. The owner leaving deletes the room and every relay row."
  def leave_room(%User{id: user_id} = user, %Room{} = room) do
    if member?(user, room) do
      if room.owner_id == user_id do
        Repo.delete(room)
      else
        Repo.delete_all(
          from m in Membership, where: m.user_id == ^user_id and m.room_id == ^room.id
        )
      end

      :ok
    else
      {:error, :not_a_member}
    end
  end

  def list_members(%Room{id: room_id}) do
    from(u in User,
      join: m in Membership,
      on: m.user_id == u.id,
      where: m.room_id == ^room_id,
      select: {u, m.role},
      order_by: u.username
    )
    |> Repo.all()
  end

  ## Invites

  @doc "Signs a 7-day invite token for `room` attributed to `inviter`."
  def invite_token(%Room{id: room_id}, %User{id: inviter_id}) do
    Phoenix.Token.sign(ClothespinWeb.Endpoint, "pin_invite", %{
      room_id: room_id,
      inviter_id: inviter_id
    })
  end

  @doc "`{:ok, room}` when the invite token is valid and the room still exists."
  def verify_invite(token) when is_binary(token) do
    with {:ok, %{room_id: room_id}} <-
           Phoenix.Token.verify(ClothespinWeb.Endpoint, "pin_invite", token,
             max_age: @invite_max_age
           ),
         %Room{} = room <- get_room(room_id) do
      {:ok, room}
    else
      _ -> {:error, :invalid_invite}
    end
  end

  def invite_url(%Room{} = room, %User{} = inviter) do
    ClothespinWeb.Endpoint.url() <> "/join/" <> invite_token(room, inviter)
  end

  ## Bridge tokens

  @doc """
  Signs a no-expiry bridge token; validity is the membership at connect time,
  so leaving (or the owner deleting) the room revokes it.
  """
  def bridge_token(%User{id: user_id}, %Room{id: room_id}) do
    Phoenix.Token.sign(ClothespinWeb.Endpoint, "bridge", %{user_id: user_id, room_id: room_id})
  end

  @doc "`{:ok, user, room}` when the token decodes and membership still holds."
  def verify_bridge(token) when is_binary(token) do
    with {:ok, %{user_id: user_id, room_id: room_id}} <-
           Phoenix.Token.verify(ClothespinWeb.Endpoint, "bridge", token, max_age: :infinity),
         %Room{} = room <- get_room(room_id),
         %User{} = user <- Clothespin.Accounts.get_user(user_id),
         true <- member?(user, room) do
      {:ok, user, room}
    else
      _ -> {:error, :invalid_bridge_token}
    end
  end

  ## Setup instructions

  @doc """
  The one source of truth for the bridge command, used by the web UI and the
  MCP tools.
  """
  def bridge_command(server_url, token, site_name \\ nil) do
    base =
      "mix pin.connect --server #{server_url} --bridge-token #{token} " <>
        "--clothesline http://127.0.0.1:19004/mcp"

    if site_name, do: base <> " --site #{site_name}", else: base
  end

  @doc "Base URL agents should use for this clothespin instance."
  def server_url, do: ClothespinWeb.Endpoint.url()
end
