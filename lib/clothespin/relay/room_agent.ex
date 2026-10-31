defmodule Clothespin.Relay.RoomAgent do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "room_agents" do
    field :site_name, :string
    field :agent_ref, :string
    field :external_id, :string
    field :state, :string, default: "online"
    field :status_message, :string
    field :last_seen_at, :utc_datetime

    belongs_to :room, Clothespin.Pins.Room, type: :binary_id

    timestamps()
  end
end
