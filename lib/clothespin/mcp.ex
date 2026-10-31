defmodule Clothespin.MCP do
  @moduledoc """
  The clothespin MCP server, mounted at `/mcp`.

  Tools mirror the web flows so an agent can pin a session end to end:
  `create_account`, `login`, `whoami`, `pin_session`, `join_pin`,
  `pin_status`, `pin_stop`. Every stateful tool takes a `token` from
  `login` — attribution-style auth, like clothesline presence. Results are
  JSON-encoded text content, the same shape clothesline uses.
  """

  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "clothespin", version: "0.1.0"

  alias Clothespin.{Accounts, Pins, Relay, SiteRegistry}

  @agent_token_max_age 7_776_000

  tool "create_account",
       "Create a clothespin account. Requires username (3-32 chars: a-z, 0-9, -), display_name, and passphrase (12+ characters). After this, call login." do
    param(:username, :string, required: true)
    param(:display_name, :string, required: true)
    param(:passphrase, :string, required: true)

    run(fn args, state ->
      case Accounts.create_user(%{
             username: args["username"],
             display_name: args["display_name"],
             passphrase: args["passphrase"]
           }) do
        {:ok, user} ->
          json_result(%{username: user.username, display_name: user.display_name}, state)

        {:error, :taken} ->
          error_result("username is already taken", state)

        {:error, %Ecto.Changeset{} = changeset} ->
          error_result(changeset_error(changeset), state)
      end
    end)
  end

  tool "login",
       "Log in with username + passphrase. Returns a token for all other tools (valid 90 days)." do
    param(:username, :string, required: true)
    param(:passphrase, :string, required: true)

    run(fn args, state ->
      case Accounts.authenticate(args.username, args.passphrase) do
        {:ok, user} ->
          json_result(
            %{token: Accounts.agent_token(user), expires_in: @agent_token_max_age},
            state
          )

        {:error, :invalid} ->
          error_result("wrong username or passphrase", state)
      end
    end)
  end

  tool "whoami", "Show the account for a token, with your pins (rooms)." do
    param(:token, :string, required: true)

    run(fn args, state ->
      with {:ok, user} <- auth(args.token) do
        pins =
          Enum.map(Pins.list_rooms(user), fn room ->
            %{
              room_id: room.id,
              title: room.title,
              role: if(room.owner_id == user.id, do: "owner", else: "member")
            }
          end)

        json_result(
          %{username: user.username, display_name: user.display_name, pins: pins},
          state
        )
      else
        {:error, reason} -> error_result(reason, state)
      end
    end)
  end

  tool "pin_session",
       "Pin this machine into a NEW shared room: creates the pin, returns invite_url, bridge_token, and the exact bridge_command to run (mix pin.connect) to connect this machine's clothesline. Share invite_url with teammates." do
    param(:token, :string, required: true)
    param(:title, :string, required: true)

    param(:site_name, :string,
      required: false,
      default: nil,
      description: "Short name for this machine on the pin (default: hostname)"
    )

    run(fn args, state ->
      with {:ok, user} <- auth(args.token),
           {:ok, room} <- Pins.create_room(user, args.title) do
        token = Pins.bridge_token(user, room)
        site = site_name(args.site_name)

        json_result(
          %{
            room_id: room.id,
            invite_url: Pins.invite_url(room, user),
            server_url: Pins.server_url(),
            bridge_token: token,
            bridge_command: Pins.bridge_command(Pins.server_url(), token, site)
          },
          state
        )
      else
        {:error, reason} when is_binary(reason) ->
          error_result(reason, state)

        {:error, %Ecto.Changeset{} = changeset} ->
          error_result(changeset_error(changeset), state)

        {:error, reason} ->
          error_result(inspect(reason), state)
      end
    end)
  end

  tool "join_pin",
       "Join an existing pin from an invite URL (7-day expiry). Returns bridge_token and the bridge_command to run to connect this machine's clothesline." do
    param(:token, :string, required: true)
    param(:invite_url, :string, required: true)

    run(fn args, state ->
      invite_token = extract_token(args.invite_url, "/join/")

      with {:ok, user} <- auth(args.token),
           {:ok, room} <- Pins.verify_invite(invite_token),
           :ok <- Pins.ensure_member(user, room) do
        token = Pins.bridge_token(user, room)
        site = site_name(nil)

        json_result(
          %{
            room_id: room.id,
            server_url: Pins.server_url(),
            bridge_token: token,
            bridge_command: Pins.bridge_command(Pins.server_url(), token, site)
          },
          state
        )
      else
        {:error, reason} when is_binary(reason) ->
          error_result(reason, state)

        {:error, reason} ->
          error_result(inspect(reason), state)
      end
    end)
  end

  tool "pin_status",
       "Check a pin: which bridge sites are connected, mirrored agents, and message/conversation counts." do
    param(:token, :string, required: true)
    param(:room_id, :string, required: true)

    run(fn args, state ->
      with {:ok, user} <- auth(args.token),
           {:ok, room} <- fetch_member_room(user, args.room_id) do
        snapshot = Relay.snapshot(room)

        json_result(
          %{
            bridges: SiteRegistry.sites(room.id),
            agents:
              Enum.map(snapshot.agents, fn agent ->
                %{
                  site_name: agent.site_name,
                  external_id: agent.external_id,
                  state: agent.state,
                  status_message: agent.status_message
                }
              end),
            conversations: length(snapshot.conversations),
            messages: length(snapshot.messages)
          },
          state
        )
      else
        {:error, reason} when is_binary(reason) ->
          error_result(reason, state)

        {:error, reason} ->
          error_result(inspect(reason), state)
      end
    end)
  end

  tool "pin_stop",
       "Leave a pin. The owner leaving deletes the pin for everyone (all relay rows cascade). Your bridge token stops working immediately." do
    param(:token, :string, required: true)
    param(:room_id, :string, required: true)

    run(fn args, state ->
      with {:ok, user} <- auth(args.token),
           {:ok, room} <- fetch_member_room(user, args.room_id),
           :ok <- Pins.leave_room(user, room) do
        json_result(%{left: true}, state)
      else
        {:error, reason} when is_binary(reason) ->
          error_result(reason, state)

        {:error, reason} ->
          error_result(inspect(reason), state)
      end
    end)
  end

  ## Helpers

  defp auth(nil), do: {:error, "missing token: log in first"}
  defp auth(token), do: Accounts.verify_agent_token(token)

  defp fetch_member_room(user, room_id) do
    case Pins.get_room(room_id) do
      %Pins.Room{} = room ->
        if Pins.member?(user, room),
          do: {:ok, room},
          else: {:error, "you are not a member of that pin"}

      nil ->
        {:error, "unknown pin"}
    end
  end

  defp site_name(nil) do
    {:ok, host} = :inet.gethostname()
    host |> to_string() |> String.split(".") |> List.first() |> String.downcase()
  end

  defp site_name(name), do: name

  defp extract_token(url, marker) do
    case String.split(url, marker, parts: 2) do
      [_before, token] -> String.split(token, "?") |> List.first()
      [_] -> url
    end
  end

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end

  defp json_result(map, state) do
    {:ok, %{content: [%{type: "text", text: Jason.encode!(map)}]}, state}
  end

  defp error_result(message, state) do
    {:ok, %{content: [%{type: "text", text: Jason.encode!(%{error: message})}], isError: true},
     state}
  end
end
