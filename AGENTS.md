# AGENTS.md

Guidance for coding agents working in this repo.

## What this is

Clothespin bridges local [clothesline](https://github.com/) MCP message-bus
sessions across machines. Each participant runs `mix pin.connect` locally; it
connects their clothesline `/mcp` endpoint to a shared pin (room) on the
clothespin server over a WebSocket (`/bridge`). Agents on different machines
then see each other's conversations, messages, and presence on their own bus.

## Layout

- `lib/clothespin/` — domain: `Accounts` (users), `Pins` (rooms, invites,
  bridge tokens), `Relay` (room agents/conversations/messages persistence).
- `lib/clothespin/bridge/` — the daemon side: `Registry` (harness + mirror
  cache), `Link` (gun WebSocket client), `Pump` (local→pin: poll/forward),
  `Injector` (pin→local: message/event injection), `McpClient` (Req JSON-RPC).
- `lib/clothespin_web/` — Phoenix: room chat UI, `/bridge` socket,
  `/mcp` endpoint (`Clothespin.MCP`).
- `lib/mix/tasks/pin.connect.ex` — the daemon CLI.
- `scripts/e2e_mcp.py` — full cross-machine E2E (run via `scripts/e2e.sh`).

## Conventions

- Never modify the sibling `../clothesline` checkout; it is a pinned 0.9.1
  dependency, treated as read-only.
- clothesline semantics to respect in bridge code: `status` is derived
  (online/stale/offline); human status text lives in `status_message`;
  `client_message_id` dedupes per sender; polling excludes the sender's own
  broadcasts.
- All cross-machine messages are escaped plain text — never render raw HTML.
- Mirror agents on a local bus are named `pin:<site>:<ref-prefix>`; they
  belong to the bridge's own harness (`clothespin-bridge:<site>`
  installation key), never to user harnesses.

## Commands

```sh
mix deps.get && mix compile --warnings-as-errors   # must be clean
mix test                                           # must be green
mix phx.server                                     # dev server on :4000
mix pin.connect --server http://localhost:4000 --bridge-token <t> \
  --clothesline http://127.0.0.1:8080/mcp --site my-site
scripts/e2e.sh                                     # provisions buses + pin, runs E2E
```

## Testing rules

- Unit tests cover relay/accounts/MCP/socket behavior; the bridge daemon is
  verified by `scripts/e2e.sh` (live two-bus run) — keep that script passing.
- DB: Postgres per `config/test.exs`; Homebrew Postgres on this machine
  (`/tmp` socket, role `kplawver`, no password).
