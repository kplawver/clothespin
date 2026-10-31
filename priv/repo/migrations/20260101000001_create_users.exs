defmodule Clothespin.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF NOT EXISTS citext"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :username, :citext, null: false
      add :display_name, :text, null: false
      add :password_hash, :text, null: false

      timestamps()
    end

    create unique_index(:users, [:username])
  end
end
