defmodule Clothespin.Relay.Message do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "room_messages" do
    field :room_id, :binary_id
    field :sender_key, :string
    field :sender_name, :string
    field :sender_site, :string
    field :recipient_agent_ref, :string
    field :recipient_site, :string
    field :client_message_id, :string
    field :body, :string

    belongs_to :conversation, Clothespin.Relay.Conversation, type: :binary_id

    timestamps(inserted_at: :inserted_at, updated_at: false)
  end
end
