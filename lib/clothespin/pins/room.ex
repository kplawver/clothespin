defmodule Clothespin.Pins.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "rooms" do
    field :title, :string
    belongs_to :owner, Clothespin.Accounts.User, type: :binary_id

    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:title, :owner_id])
    |> validate_required([:title, :owner_id])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, min: 1, max: 200)
    |> foreign_key_constraint(:owner_id)
  end
end
