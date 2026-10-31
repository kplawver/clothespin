defmodule Clothespin.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @username_re ~r/^[a-z0-9-]{3,32}$/

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "users" do
    field :username, :string
    field :display_name, :string
    field :password_hash, :string

    # Write-only: hashed into password_hash by registration_changeset/2.
    field :passphrase, :string, virtual: true, redact: true

    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :passphrase])
    |> validate_required([:username, :display_name, :passphrase])
    |> update_change(:username, &String.downcase/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_format(:username, @username_re,
      message: "must be 3-32 chars of lowercase letters, digits, or hyphens"
    )
    |> validate_length(:display_name, min: 1, max: 100)
    |> validate_length(:passphrase, min: 12)
    |> unique_constraint(:username, name: :users_username_index)
    |> put_password_hash()
  end

  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{passphrase: passphrase}} = changeset
       ) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(passphrase))
  end

  defp put_password_hash(changeset), do: changeset
end
