defmodule Clothespin.Accounts do
  @moduledoc """
  Username + passphrase accounts. No email, no confirmation: identity inside
  clothespin is attribution-style, like clothesline presence itself.
  """

  alias Clothespin.Accounts.User
  alias Clothespin.Repo

  @agent_token_max_age 90 * 24 * 3600

  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  def get_user_by_username(username) when is_binary(username),
    do: Repo.get_by(User, username: String.downcase(username))

  @doc "Creates a user. `{:error, :taken}` when the username is already used."
  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{errors: [username: {"has already been taken", _}]}} ->
        {:error, :taken}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Returns `{:ok, user}` or `{:error, :invalid}`."
  def authenticate(username, passphrase) when is_binary(username) and is_binary(passphrase) do
    if user = get_user_by_username(username) do
      if Bcrypt.verify_pass(passphrase, user.password_hash),
        do: {:ok, user},
        else: {:error, :invalid}
    else
      # Equal bcrypt work on unknown usernames: login timing does not reveal
      # whether the account exists.
      Bcrypt.no_user_verify()
      {:error, :invalid}
    end
  end

  def authenticate(_, _), do: {:error, :invalid}

  @doc "Signs a 90-day agent token (used by the MCP tools)."
  def agent_token(%User{id: id}),
    do: Phoenix.Token.sign(ClothespinWeb.Endpoint, "agent_auth", id)

  @doc "Verifies an agent token; `{:error, :invalid_token}` when absent, tampered, or expired."
  def verify_agent_token(token) when is_binary(token) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(ClothespinWeb.Endpoint, "agent_auth", token,
             max_age: @agent_token_max_age
           ),
         %User{} = user <- get_user(user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify_agent_token(_), do: {:error, :invalid_token}
end
