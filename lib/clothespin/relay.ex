defmodule Clothespin.Relay do
  @moduledoc """
  The relay core: idempotent messages, agent presence, conversations, routing.

  Pure Ecto — no transport knowledge. Both the browser channel (step 4) and
  the bridge socket (step 5) call only this module. Semantics mirror
  clothesline's bus: sends are idempotent per `(sender_key, client_message_id)`,
  a reused id with different content is a conflict, direct messages carry a
  named recipient while broadcasts reach whoever is attached now.
  """

  import Ecto.Query
  alias Clothespin.Pins.Room
  alias Clothespin.Relay.{Conversation, Message, RoomAgent}
  alias Clothespin.Repo

  @max_body 100_000
  @max_client_message_id 256

  ## Conversations

  @doc """
  Get-or-insert a conversation. Foreign conversations dedupe on the partial
  unique key `(room_id, origin_site, origin_ref)`; web-opened conversations
  (`origin_site: nil`) are always new rows.
  """
  def upsert_conversation(%Room{id: room_id}, attrs) do
    attrs = Map.take(attrs, [:title, :project_key, :created_by, :origin_site, :origin_ref])

    cond do
      is_binary(attrs[:title]) and attrs[:title] != "" and is_binary(attrs[:origin_site]) ->
        if is_nil(attrs[:origin_ref]) or attrs[:origin_ref] == "" do
          {:error, :origin_ref_required}
        else
          changeset =
            %Conversation{}
            |> Ecto.Changeset.cast(attrs, [:title, :project_key, :created_by])
            |> Ecto.Changeset.change(
              room_id: room_id,
              origin_site: attrs[:origin_site],
              origin_ref: attrs[:origin_ref]
            )

          Repo.insert(changeset,
            on_conflict: :nothing,
            conflict_target:
              {:unsafe_fragment,
               "(room_id, origin_site, origin_ref) WHERE origin_site IS NOT NULL"}
          )
          |> case do
            {:ok, _maybe_conflicted} ->
              # binary ids are generated client-side, so a conflicted insert
              # still returns a struct; the origin key is the truth.
              {:ok, get_conversation_by_origin(room_id, attrs[:origin_site], attrs[:origin_ref])}

            {:error, changeset} ->
              {:error, changeset}
          end
        end

      is_binary(attrs[:title]) and attrs[:title] != "" ->
        %Conversation{}
        |> Ecto.Changeset.cast(attrs, [:title, :project_key, :created_by])
        |> Ecto.Changeset.change(room_id: room_id)
        |> Repo.insert()

      true ->
        {:error, :title_required}
    end
  end

  def get_conversation(room_id, conversation_id) do
    Repo.one(from c in Conversation, where: c.room_id == ^room_id and c.id == ^conversation_id)
  end

  def get_conversation_by_origin(room_id, origin_site, origin_ref) do
    Repo.one(
      from c in Conversation,
        where:
          c.room_id == ^room_id and c.origin_site == ^origin_site and c.origin_ref == ^origin_ref
    )
  end

  ## Agent presence

  @doc """
  Upserts a room agent row. Events: `"online"`, `"stale"`, `"offline"`,
  `"heartbeat"`. `last_seen_at` refreshes on online/heartbeat; offline clears
  the status message (clothesline signs off the same way).
  """
  def record_agent_event(%Room{id: room_id}, attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {state, status_message, touch} =
      case attrs[:event] do
        "online" -> {"online", attrs[:status_message], true}
        "stale" -> {"stale", attrs[:status_message], false}
        "offline" -> {"offline", nil, false}
        "heartbeat" -> {nil, attrs[:status_message], true}
        other -> {other, attrs[:status_message], false}
      end

    changes =
      %{
        room_id: room_id,
        site_name: attrs[:site_name],
        agent_ref: attrs[:agent_ref],
        external_id: attrs[:external_id] || attrs[:agent_ref],
        state: state || "online",
        status_message: status_message,
        last_seen_at: now
      }

    replace =
      ([:external_id, :state] ++
         if(status_message, do: [:status_message], else: []) ++
         if(touch, do: [:last_seen_at], else: []) ++
         if(attrs[:event] == "offline", do: [:status_message], else: []))
      |> Enum.uniq()

    %RoomAgent{}
    |> Ecto.Changeset.change(changes)
    |> Repo.insert(
      on_conflict: {:replace, replace},
      conflict_target: [:room_id, :site_name, :agent_ref]
    )
  end

  def list_agents(%Room{id: room_id}) do
    Repo.all(from a in RoomAgent, where: a.room_id == ^room_id, order_by: a.site_name)
  end

  ## Messages

  @doc """
  Records a message idempotently per `(room_id, sender_key, client_message_id)`.

  Returns `{:ok, message, duplicate?}`. Reusing a client_message_id with
  different `(conversation, body, recipient)` is
  `{:error, :client_message_id_conflict}` — clothesline's `bus.py:141` rule.
  """
  def record_message(%Room{id: room_id}, attrs) do
    with {:ok, changeset} <- message_changeset(room_id, attrs) do
      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:room_id, :sender_key, :client_message_id],
             returning: true
           ) do
        {:ok, %Message{id: nil}} ->
          compare_existing(room_id, attrs)

        {:ok, %Message{} = message} ->
          {:ok, message, false}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp message_changeset(room_id, attrs) do
    body = attrs[:body] || ""
    client_message_id = attrs[:client_message_id] || ""

    cond do
      client_message_id == "" or byte_size(client_message_id) > @max_client_message_id ->
        {:error, :invalid_client_message_id}

      String.trim(body) == "" or byte_size(body) > @max_body ->
        {:error, :invalid_body}

      true ->
        {:ok,
         %Message{}
         |> Ecto.Changeset.change(
           room_id: room_id,
           conversation_id: attrs[:conversation].id,
           sender_key: attrs[:sender_key],
           sender_name: attrs[:sender_name],
           sender_site: attrs[:sender_site],
           recipient_agent_ref: attrs[:recipient_agent_ref],
           recipient_site: attrs[:recipient_site],
           client_message_id: client_message_id,
           body: body
         )}
    end
  end

  defp compare_existing(room_id, attrs) do
    existing =
      Repo.one(
        from m in Message,
          where:
            m.room_id == ^room_id and m.sender_key == ^attrs[:sender_key] and
              m.client_message_id == ^attrs[:client_message_id]
      )

    if existing &&
         {existing.conversation_id, existing.body, existing.recipient_agent_ref} ==
           {attrs[:conversation].id, attrs[:body], attrs[:recipient_agent_ref]} do
      {:ok, existing, true}
    else
      {:error, :client_message_id_conflict}
    end
  end

  ## Routing

  @doc """
  Direct messages (recipient set) go to the named site's bridge — even if that
  site's agent row is missing or stale, cross-site delivery is still addressed
  only to it. Broadcasts fan out to every attached bridge except the sender's.
  """
  def route(%Message{} = message) do
    if message.recipient_site do
      %{direct_sites: [message.recipient_site], broadcast: false}
    else
      %{direct_sites: [], broadcast: true}
    end
  end

  ## Snapshot

  @doc """
  Full room state for catch-up and page render: last `limit` messages (asc),
  agents, and conversations.
  """
  def snapshot(%Room{id: room_id}, limit \\ 200) do
    messages =
      Repo.all(
        from m in Message,
          where: m.room_id == ^room_id,
          order_by: [desc: m.id],
          limit: ^limit
      )
      |> Enum.reverse()

    %{
      messages: messages,
      agents: list_agents(%Room{id: room_id}),
      conversations:
        Repo.all(from c in Conversation, where: c.room_id == ^room_id, order_by: c.inserted_at)
    }
  end

  ## Payloads

  @doc """
  The canonical `message_new` payload shared by browsers and bridges: one
  shape, embedded conversation metadata so bridges can lazily mirror.
  """
  def message_payload(%Message{} = message, %Conversation{} = conversation) do
    %{
      message_id: message.id,
      conversation: %{
        id: conversation.id,
        title: conversation.title,
        project_key: conversation.project_key,
        origin_site: conversation.origin_site,
        origin_ref: conversation.origin_ref
      },
      sender_kind: (String.starts_with?(message.sender_key, "human:") && "human") || "agent",
      sender_site: message.sender_site,
      sender_agent_ref: agent_ref_of(message.sender_key),
      sender_external_id: message.sender_name,
      sender_name: message.sender_name,
      recipient_site: message.recipient_site,
      recipient_agent_ref: message.recipient_agent_ref,
      client_message_id: message.client_message_id,
      body: message.body,
      inserted_at: message.inserted_at
    }
  end

  defp agent_ref_of("agent:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [_site, ref] -> ref
      _ -> nil
    end
  end

  defp agent_ref_of(_), do: nil
end
