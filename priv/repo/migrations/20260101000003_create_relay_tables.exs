defmodule Clothespin.Repo.Migrations.CreateRelayTables do
  use Ecto.Migration

  def change do
    create table(:room_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :site_name, :text, null: false
      add :agent_ref, :text, null: false
      add :external_id, :text, null: false
      add :state, :text, null: false, default: "online"
      add :status_message, :text
      add :last_seen_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:room_agents, [:room_id, :site_name, :agent_ref])
    create index(:room_agents, [:room_id, :site_name])

    create table(:room_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :origin_site, :text
      add :origin_ref, :text
      add :title, :text, null: false
      add :project_key, :text
      add :created_by, :text

      timestamps()
    end

    create index(:room_conversations, [:room_id])

    create unique_index(:room_conversations, [:room_id, :origin_site, :origin_ref],
             where: "origin_site IS NOT NULL",
             name: :room_conversations_origin_key_index
           )

    create table(:room_messages, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :conversation_id,
          references(:room_conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sender_key, :text, null: false
      add :sender_name, :text, null: false
      add :sender_site, :text
      add :recipient_agent_ref, :text
      add :recipient_site, :text
      add :client_message_id, :text, null: false
      add :body, :text, null: false

      timestamps(inserted_at: :inserted_at, updated_at: false)
    end

    create unique_index(:room_messages, [:room_id, :sender_key, :client_message_id])
    create index(:room_messages, [:room_id, :conversation_id])
  end
end
