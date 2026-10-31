defmodule Clothespin.Repo.Migrations.CreateRoomsAndMemberships do
  use Ecto.Migration

  def change do
    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :text, null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create table(:memberships, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :role, :text, null: false, default: "member"

      timestamps()
    end

    create unique_index(:memberships, [:user_id, :room_id])
    create index(:memberships, [:room_id])
  end
end
