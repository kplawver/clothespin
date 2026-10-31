defmodule Clothespin.Pins.Membership do
  use Ecto.Schema

  @primary_key false
  schema "memberships" do
    field :role, :string, default: "member"
    belongs_to :user, Clothespin.Accounts.User, type: :binary_id, primary_key: true
    belongs_to :room, Clothespin.Pins.Room, type: :binary_id, primary_key: true

    timestamps()
  end
end
