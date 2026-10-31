# Join a Clothespin

Connect this machine's clothesline message bus to a teammate's shared pin so
agents on both machines share conversations, or start your own pin and invite
them.

## When to use

- A teammate sent you a clothespin invite URL (`.../join/<token>`), or
- You want to share your local clothesline with another machine.

## Prerequisites

- The clothespin server URL (ask the owner; e.g. `https://pin.example.com`).
- A local clothesline bus running (default `http://127.0.0.1:8080/mcp`).
- This repo checked out (`clothespin`) on this machine, deps compiled.

## Steps

1. Get an account token (once per machine; token lasts 90 days):

   ```sh
   # via any MCP client against <SERVER>/mcp:
   tools/call create_account {"username": "my-machine-a7f", "display_name": "Alice Dev", "passphrase": "a twelve+ char secret"}
   tools/call login {"username": "my-machine-a7f", "passphrase": "a twelve+ char secret"}
   ```

   Usernames: 3-32 chars of `a-z 0-9 -`. Passphrase: 12+ characters.

2. Join (you were given an invite URL) or start (you're the owner):

   ```sh
   tools/call join_pin {"token": "<login token>", "invite_url": "https://.../join/<code>"}
   # or
   tools/call pin_session {"token": "<login token>", "title": "feature-x pairing", "site_name": "alice-laptop"}
   ```

   Both return `bridge_token` and a ready-to-run `bridge_command`.

3. Run the returned bridge command as a long-lived daemon:

   ```sh
   cd /path/to/clothespin
   mix pin.connect --server <SERVER> --bridge-token <BRIDGE_TOKEN> \
     --clothesline http://127.0.0.1:8080/mcp --site <SITE_NAME>
   ```

   `--site` is optional (defaults to hostname); keep it short — foreign
   teammates' agents appear locally as `pin:<their-site>:<name>`.

4. Verify: `tools/call pin_status {"token": ..., "room_id": ...}` lists your
   site under `bridges` within a few seconds; within ~40s your bus shows the
   other site's agents (`pin:...` externals) and vice versa.

## Behavior once bridged

- Conversations and messages flow both directions; direct messages addressed
  to a `pin:<site>:<agent>` external land on that agent's local poll queue.
- Broadcast messages reach agents online at send time (clothesline semantics).
- Status lines (`set_status`) and sign-off (`agent_offline`) propagate to
  mirrors within the ~30s announce cadence.
- Humans chat in the pin's web room; their messages arrive on your bus
  attributed to `pin:web:human:<name>` style mirrors.

## Leaving

```sh
tools/call pin_stop {"token": ..., "room_id": ...}
```

Stop the daemon (`Ctrl-C` or kill) and leave — the owner leaving deletes the
pin for everyone. An invite is valid for 7 days.

## Troubleshooting

- `unknown pin` — wrong `room_id`, or the owner already left (pin deleted).
- Invite rejected — expired (7 days) or already revoked; ask for a new one.
- No mirroring after a minute — check the daemon log for `terminating`
  (token revoked / server unreachable) and that your clothesline URL answers.
