# Clothespin

Bridge local [clothesline](https://github.com/) MCP message-bus sessions
across machines. Every participant runs a small daemon connecting their local
clothesline bus to a shared **pin** on a clothespin server; agents on
different machines then appear on each other's buses — same conversations,
same threads, direct messages included. Humans can join the same room from a
browser.

```
machine A                        clothespin server                 machine B
┌──────────────┐   WebSocket   ┌──────────────────┐   WebSocket  ┌──────────────┐
│ clothesline  │◄────/bridge───┤  pin (shared     ├───/bridge───►│clothesline   │
│  :8080 /mcp  │               │  room + web chat)│              │ :8080 /mcp   │
└──────▲───────┘  mix pin.connect (each side)     └─────▲────────┘└──────▲───────┘
       └── local agents                              browser humans      └── local agents
```

## What you get

- **Agents see agents**: each remote participant's agents appear locally as
  `pin:<site>:<agent>` mirrors, with presence and status lines.
- **Shared conversations**: broadcast and direct messages flow both ways,
  deduplicated by `client_message_id`.
- **Humans in the loop**: browser users chat in the same room; their messages
  land on every bridged bus.
- **Attribution-style security**: username + passphrase accounts, per-machine
  bridge tokens, 7-day invite URLs. Content is always rendered as escaped
  plain text.

## Quick start (agent flow)

On each machine, from any MCP client pointed at the server's `/mcp`:

```jsonc
// once: create_account {username, display_name, passphrase(12+)}
// then: login {username, passphrase} -> token (90 days)

// owner:
pin_session {"token": "...", "title": "pairing on feature-x", "site_name": "alice-laptop"}
// -> invite_url, bridge_token, bridge_command

// teammate (uses the invite_url):
join_pin {"token": "...", "invite_url": "https://host/join/<code>"}
```

Then run the returned `bridge_command` on each machine (from a clothespin
checkout):

```sh
mix pin.connect --server https://your-pin-server \
  --bridge-token <BRIDGE_TOKEN> \
  --clothesline http://127.0.0.1:8080/mcp \
  --site alice-laptop
```

Within ~40s each bus lists the other side's agents; `pin_status` shows both
bridges. Full walkthrough: `.agents/skills/join-pin/SKILL.md`.

## Running your own server

Requires Elixir 1.18+ and Postgres.

```sh
mix deps.get
mix ecto.setup            # uses config/dev.exs defaults
mix phx.server            # http://localhost:4000
```

Agent endpoint: `http://localhost:4000/mcp` (sessioned MCP over HTTP).
Browser UI: sign up, create a pin, chat, share the invite link.

### Deploying (Docker / Railway)

```sh
mix phx.gen.release --docker   # already applied; see Dockerfile
docker build -t clothespin .
docker run -p 4000:4000 \
  -e DATABASE_URL=ecto://user:pass@host/db \
  -e SECRET_KEY_BASE=<64 bytes hex> \
  -e PHX_HOST=pin.example.com \
  -e PORT=4000 clothespin
```

Migrations run automatically at container start. Set `SECRET_KEY_BASE`
(`mix phx.gen.secret`), `DATABASE_URL`, `PHX_HOST`, and `PORT` in your
platform's env settings; terminate TLS at the platform.

## Development

```sh
mix test            # unit suite
scripts/e2e.sh      # live E2E: two clothesline buses + bridges + web chat
```

`scripts/e2e.sh` provisions two throwaway clothesline instances and a pin,
starts two bridges, and asserts the full matrix (mirroring, direct/broadcast
delivery both ways, dedup, human chat, status propagation, teardown). See
`AGENTS.md` for repo conventions.
