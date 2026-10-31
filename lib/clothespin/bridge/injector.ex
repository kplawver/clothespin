defmodule Clothespin.Bridge.Injector do
  @moduledoc """
  Pin → local bus. Runs inside the Link process (synchronously, in arrival
  order): mirrors foreign participants, maintains pin-conversation →
  local-conversation mappings, and injects messages idempotently by
  `client_message_id`.
  """

  alias Clothespin.Bridge.{McpClient, Registry}

  @doc """
  Replays a hello/reconnect snapshot: foreign agent presence, then messages
  oldest→newest. Our own forwarded messages (sender_site == our site) are
  skipped — they already live on the local bus.
  """
  def reconcile_snapshot(snapshot) do
    Enum.each(snapshot["agents"] || [], &inject_agent_event/1)

    Enum.each(snapshot["messages"] || [], fn payload ->
      if payload["sender_site"] != Registry.site() do
        inject_message(payload)
      end
    end)
  end

  @doc "One message_new push (or snapshot row) onto the local bus."
  def inject_message(payload) do
    site = Registry.site()
    sender_site = payload["sender_site"]
    conv = payload["conversation"] || %{}

    with {:ok, mirror} <- ensure_sender_mirror(payload),
         {:ok, local_conv_id} <- ensure_conv_id(conv, site, mirror) do
      result =
        McpClient.tool(Registry.mcp_url(), "send_message", %{
          "conversation_id" => local_conv_id,
          "harness_id" => Registry.harness_id(),
          "agent_id" => mirror.agent_id,
          "client_message_id" => injection_cmid(sender_site, payload["client_message_id"]),
          "body" => payload["body"] || "",
          "recipient_agent_id" => local_recipient(payload)
        })

      result

    end
  end

  defp ensure_conv_id(conv, site, mirror) do
    if conv["origin_site"] == site and is_binary(conv["origin_ref"]) do
      # Conversation originated on our bus; the origin ref IS our local id.
      {:ok, conv["origin_ref"]}
    else
      case ensure_local_conversation(conv, mirror) do
        nil -> {:error, :conversation_open_failed}
        local_id -> {:ok, local_id}
      end
    end
  end

  @doc "One agent_event push: mirror the foreign agent's presence locally."
  def inject_agent_event(payload) do
    site = payload["site_name"]
    ref = payload["agent_ref"]

    if is_binary(site) and is_binary(ref) and ref != "" and site != Registry.site() do
      # The push carries the recorded state ("online" | "offline" | custom);
      # fall back to it when no explicit event came through.
      event = payload["event"] || payload["state"] || "online"

      case Registry.ensure_mirror(site, ref, payload["external_id"]) do
        {:error, _} ->
          :ok

        {:ok, mirror} ->
          harness = Registry.harness_id()
          url = Registry.mcp_url()

          # clothesline's `status` is derived (online/stale/offline); the
          # human-readable "what I'm working on" lives in status_message and
          # is set locally via set_status.
          case event do
            "offline" ->
              McpClient.tool(url, "agent_offline", %{"harness_id" => harness, "agent_id" => mirror.agent_id})

            "online" ->
              McpClient.tool(url, "agent_online", %{"harness_id" => harness, "agent_id" => mirror.agent_id})
              set_mirror_status(url, harness, mirror, payload["status_message"])

            "heartbeat" ->
              McpClient.tool(url, "agent_heartbeat", %{"harness_id" => harness, "agent_id" => mirror.agent_id})

            # "stale" is a derived liveness state; local mirrors go stale on
            # their own when the source stops announcing, so nothing to do.
            "stale" ->
              :ok

            status when is_binary(status) ->
              McpClient.tool(url, "agent_online", %{"harness_id" => harness, "agent_id" => mirror.agent_id})
              set_mirror_status(url, harness, mirror, payload["status_message"] || status)

            _ ->
              :ok
          end
      end
    else
      :ok
    end
  end

  ## Internals

  defp ensure_sender_mirror(payload) do
    case payload["sender_site"] do
      nil ->
        # Web human: attribute to a human mirror agent.
        name = payload["sender_name"] || payload["sender_external_id"] || "web"
        Registry.ensure_mirror("web", "human:#{name}", name)

      site ->
        ref = payload["sender_agent_ref"] || ""

        if ref == "" do
          {:error, :no_sender_ref}
        else
          Registry.ensure_mirror(site, ref, payload["sender_external_id"] || ref)
        end
    end
  end

  defp ensure_local_conversation(conv, opener_mirror) do
    server_conv_id = conv["id"]

    case Registry.server_conv_local(server_conv_id) do
      nil ->
        case McpClient.tool(Registry.mcp_url(), "open_conversation", %{
               "harness_id" => Registry.harness_id(),
               "agent_id" => opener_mirror.agent_id,
               "title" => conv["title"] || "bridged conversation",
               "project_key" => conv["project_key"]
             }) do
          {:ok, %{"conversation_id" => local_id}} ->
            Registry.put_server_conv(server_conv_id, local_id)
            local_id

          {:error, _reason} ->
            nil

          _other ->
            nil
        end

      local_id ->
        local_id
    end
  end

  defp injection_cmid(nil, client_message_id), do: "web:#{client_message_id}"
  defp injection_cmid(site, client_message_id), do: "#{site}:#{client_message_id}"

  defp local_recipient(payload) do
    if payload["recipient_site"] == Registry.site() and is_binary(payload["recipient_agent_ref"]) do
      Registry.local_agent_by_external(payload["recipient_agent_ref"])
    else
      nil
    end
  end

  defp set_mirror_status(_url, _harness, _mirror, nil), do: :ok

  defp set_mirror_status(url, harness, mirror, message) do
    McpClient.tool(url, "set_status", %{
      "harness_id" => harness,
      "agent_id" => mirror.agent_id,
      "status" => message
    })
  end
end
