defmodule Clothespin.Relay.Conversation do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "room_conversations" do
    field :origin_site, :string
    field :origin_ref, :string
    field :title, :string
    field :project_key, :string
    field :created_by, :string

    belongs_to :room, Clothespin.Pins.Room, type: :binary_id

    timestamps()
  end
end
