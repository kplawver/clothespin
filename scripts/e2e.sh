#!/usr/bin/env bash
# Clothespin end-to-end: provisions two clothesline buses, a pin server, two
# bridges, runs scripts/e2e_mcp.py, then tears everything down.
# Usage: scripts/e2e.sh [--keep]   (--keep skips teardown for inspection)
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

ROOT=/tmp/clothespin-e2e
A_DIR=$ROOT/cl-a
B_DIR=$ROOT/cl-b
LOG=$ROOT/e2e.log
: > "$LOG"

CL=${CLOTHESLINE_DIR:-../clothesline}   # pinned 0.9.1 checkout, read-only

say() { printf '\n=== %s ===\n' "$*"; }

cleanup() {
  say teardown
  pkill -f "pin.connect" 2>/dev/null || true
  pkill -f "cl-a.*uvicorn" 2>/dev/null || true
  pkill -f "cl-b.*uvicorn" 2>/dev/null || true
  pkill -f "clothespin-e2e.*phx" 2>/dev/null || true
}
trap '[[ "${1:-}" == --keep ]] || cleanup' EXIT

mkdir -p "$A_DIR" "$B_DIR"

say "checking clothesline at $CL"
[[ -f $CL/pyproject.toml ]] || { echo "clothesline checkout not found at $CL"; exit 1; }

# --- pin server on :4000 (test config, isolated DB) ---
say "starting clothespin server"
MIX_ENV=test mix ecto.drop --quiet 2>>"$LOG" || true
MIX_ENV=test mix ecto.create --quiet >>"$LOG" 2>&1
MIX_ENV=test mix ecto.migrate --quiet >>"$LOG" 2>&1
MIX_ENV=test PORT=4000 mix phx.server >>"$ROOT/phx.log" 2>&1 &
PHX_PID=$!
for i in $(seq 1 30); do
  curl -sf http://localhost:4000/ >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://localhost:4000/ >/dev/null || { echo "phx server did not boot"; tail -20 "$ROOT/phx.log"; exit 1; }

# --- two clothesline buses ---
start_bus() { # dir port
  (cd "$1" && CL_DATA_DIR="$1" python3 -m uvicorn --factory clothesline.app:create_app \
     --host 127.0.0.1 --port "$2" >>"$1/bus.log" 2>&1 &)
}
say "starting bus A on :19004"
start_bus "$A_DIR" 19004
say "starting bus B on :19005"
start_bus "$B_DIR" 19005
for port in 19004 19005; do
  for i in $(seq 1 30); do curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 1; done
  curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "bus :$port did not boot"; tail -20 "$ROOT/bus.log"; exit 1; }
done

# --- pin + bridges via MCP (mirrors the real agent flow) ---
say "creating pin and starting bridges"
python3 - "$ROOT" <<'PY'
import json, os, subprocess, urllib.request, urllib.error
root = os.environ["ROOT"]  # placeholder, see argv
PY
python3 - "$ROOT" <<'PY'
import json, subprocess, sys, urllib.request, urllib.error
root = sys.argv[1]
BASE = "http://localhost:4000/mcp"

def client(name):
    sid, n = [None], [0]
    def rpc(method, params):
        n[0] += 1
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if sid[0]:
            h["Mcp-Session-Id"] = sid[0]
        req = urllib.request.Request(BASE, data=json.dumps(
            {"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}).encode(), headers=h)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                if r.headers.get("mcp-session-id"):
                    sid[0] = r.headers.get("mcp-session-id")
                body = r.read()
        except urllib.error.HTTPError as e:
            body = e.read()
        return json.loads(body) if body else {}
    def tool(t, args):
        r = rpc("tools/call", {"name": t, "arguments": args})
        if "result" not in r:
            raise RuntimeError(f"{t}: {r}")
        return json.loads(r["result"]["content"][0]["text"])
    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": name, "version": "0"}})
    return tool

t = client("e2e-setup")
import time
stamp = str(int(time.time()))
t("create_account", {"username": f"e2e-owner-{stamp}", "display_name": "E2E Owner",
                     "passphrase": "owner passphrase 123"})
owner = t("login", {"username": f"e2e-owner-{stamp}", "passphrase": "owner passphrase 123"})["token"]
session = t("pin_session", {"token": owner, "title": f"e2e {stamp}", "site_name": "alpha"})
inv = t("join_pin", {"token": owner, "invite_url": session["invite_url"]})
# owner bridge = alpha; a second account for beta
t("create_account", {"username": f"e2e-beta-{stamp}", "display_name": "E2E Beta",
                     "passphrase": "beta passphrase 123"})
beta = t("login", {"username": f"e2e-beta-{stamp}", "passphrase": "beta passphrase 123"})["token"]
bj = t("join_pin", {"token": beta, "invite_url": session["invite_url"]})

json.dump({"alpha": session["bridge_token"], "beta": bj["bridge_token"],
           "room_id": session["room_id"]}, open(f"{root}/tokens.json", "w"))

subprocess.Popen(["mix", "pin.connect", "--server", "http://localhost:4000",
                  "--bridge-token", session["bridge_token"],
                  "--clothesline", "http://127.0.0.1:19004/mcp", "--site", "alpha"],
                 stdout=open(f"{root}/bridge-a.log", "w"), stderr=subprocess.STDOUT)
subprocess.Popen(["mix", "pin.connect", "--server", "http://localhost:4000",
                  "--bridge-token", bj["bridge_token"],
                  "--clothesline", "http://127.0.0.1:19005/mcp", "--site", "beta"],
                 stdout=open(f"{root}/bridge-b.log", "w"), stderr=subprocess.STDOUT)
print("pin ready:", session["room_id"])
PY

for i in $(seq 1 30); do
  n=$(pgrep -fc "pin.connect" || true)
  [[ "$n" -ge 2 ]] && break
  sleep 1
done
[[ "$(pgrep -fc 'pin.connect' || true)" -ge 2 ]] || { echo "bridges did not start"; cat "$ROOT/bridge-a.log" "$ROOT/bridge-b.log"; exit 1; }

say "running e2e assertions"
CLOTHESPIN_URL=http://localhost:4000 \
BUS_A_URL=http://127.0.0.1:19004/mcp \
BUS_B_URL=http://127.0.0.1:19005/mcp \
  python3 scripts/e2e_mcp.py 2>&1 | tee -a "$LOG"
