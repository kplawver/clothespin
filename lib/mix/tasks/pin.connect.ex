defmodule Mix.Tasks.Pin.Connect do
  @shortdoc "Connect this machine's clothesline bus to a clothespin"

  @moduledoc """
  Connect the local clothesline bus to a pin.

      mix pin.connect --server https://pin.example.com \\
        --bridge-token TOKEN \\
        --clothesline http://127.0.0.1:19004/mcp \\
        --site laptop \\
        --poll-ms 2000

  * `--server` clothespin base URL (from pin_session/join_pin bridge_command)
  * `--bridge-token` the site's bridge token
  * `--clothesline` local clothesline MCP endpoint
  * `--site` site name on the pin (default: hostname)
  * `--poll-ms` local bus poll cadence (default 2000)

  Identity is durable: the bridge registers harness installation key
  `clothespin-bridge:<site>`, so agent and conversation mappings survive
  restarts without local state. Ctrl+C stops the bridge.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _pos, invalid} =
      OptionParser.parse(args,
        strict: [
          server: :string,
          bridge_token: :string,
          clothesline: :string,
          site: :string,
          poll_ms: :integer
        ],
        aliases: [t: :bridge_token]
      )

    missing = missing_required(opts)

    cond do
      invalid != [] ->
        Mix.raise("unknown options: #{inspect(invalid)}")

      missing != [] ->
        Mix.raise("missing required options: #{inspect(missing)}. See mix help pin.connect")
      true ->
        config = build_config(opts)
        IO.puts("[pin] site=#{config[:site]} bus=#{config[:mcp_url]} server=#{config[:server]}")

        case Clothespin.Bridge.start_link(config) do
          {:ok, _sup} ->
            IO.puts("[pin] bridge running — Ctrl+C to stop")
            :timer.sleep(:infinity)

          {:error, reason} ->
            Mix.raise("bridge failed to start: #{inspect(reason)}")
        end
    end
  end

  defp missing_required(opts) do
    Enum.filter([:server, :bridge_token, :clothesline], &is_nil(opts[&1]))
  end

  defp build_config(opts) do
    site = opts[:site] || default_site()

    [
      server: String.trim_trailing(opts[:server], "/"),
      token: opts[:bridge_token],
      mcp_url: opts[:clothesline],
      site: site,
      poll_ms: opts[:poll_ms] || 2_000
    ]
  end

  defp default_site do
    {:ok, host} = :inet.gethostname()

    host
    |> to_string()
    |> String.split(".")
    |> List.first()
    |> String.downcase()
  end
end
