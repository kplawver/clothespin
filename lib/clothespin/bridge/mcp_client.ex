defmodule Clothespin.Bridge.McpClient do
  @moduledoc """
  Minimal stateless MCP client for a clothesline bus.

  Clothesline serves `/mcp` as stateless streamable HTTP: every call is an
  independent JSON-RPC POST, no session, no SSE. We keep one Req connection
  pool per base URL and speak raw JSON-RPC — no client session state to
  break when the bus restarts.
  """

  @headers [
    {"content-type", "application/json"},
    {"accept", "application/json, text/event-stream"}
  ]

  @type url :: String.t()

  @spec initialize(url(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def initialize(base_url, client_name, version) do
    call(base_url, "initialize", %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => client_name, "version" => version}
    })
  end

  @doc """
  Calls a tool. Returns `{:ok, decoded_result_map}` where the result map is
  the JSON clothesline encoded in the text content, `{:error, msg}` when the
  tool itself failed (isError / JSON error body), or `{:error, {:transport, reason}}`.
  """
  @spec tool(url(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tool(base_url, name, arguments) do
    case call(base_url, "tools/call", %{"name" => name, "arguments" => arguments}) do
      {:ok, %{"content" => [%{"text" => text} | _]} = result} ->
        case Jason.decode(text) do
          {:ok, decoded} when is_map(decoded) ->
            if result["isError"] do
              {:error, decoded["error"] || decoded}
            else
              {:ok, decoded}
            end

          _ ->
            {:error, {:bad_content, text}}
        end

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      error ->
        error
    end
  end

  @doc "Raw JSON-RPC call. Public for smoke tests."
  @spec call(url(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(base_url, method, params) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: method,
        params: params
      })

    case Req.post(base_url, headers: @headers, body: body, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case decode(body) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => %{"message" => msg}}} -> {:error, msg}
          _ -> {:error, {:http, status}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp decode(body) when is_binary(body) do
    cond do
      body =~ "data:" ->
        # SSE: take the first data: JSON line.
        line =
          body
          |> String.split("\n")
          |> Enum.find(&String.starts_with?(&1, "data:"))

        line && line |> String.trim_leading("data:") |> String.trim() |> Jason.decode()

      true ->
        Jason.decode(body)
    end
  end

  defp decode(body) when is_map(body), do: {:ok, body}
end
