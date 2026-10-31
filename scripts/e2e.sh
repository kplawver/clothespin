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
rm -rf "$A_DIR" "$B_DIR"   # fresh SQLite per run
mkdir -p "$ROOT" "$A_DIR" "$B_DIR"
: > "$LOG"


CL=$(cd "${CLOTHESLINE_DIR:-../clothesline}" && pwd)   # pinned 0.9.1 checkout, read-only

say() { printf '\n=== %s ===\n' "$*"; }


cleanup() {
  say teardown
  pkill -f "pin.connect" 2>/dev/null || true
  pkill -f "clothesline.cli" 2>/dev/null || true
  [[ -n "${PHX_PID:-}" ]] && kill "$PHX_PID" 2>/dev/null || true
}
trap 'cleanup' EXIT

if [[ "${1:-}" == "--keep" ]]; then
  trap - EXIT
fi


# --- pin server on :4000 (test config, isolated DB) ---
say "starting clothespin server"
MIX_ENV=test mix ecto.drop --quiet 2>>"$LOG" || true
MIX_ENV=test mix ecto.create --quiet >>"$LOG" 2>&1
MIX_ENV=test mix ecto.migrate --quiet >>"$LOG" 2>&1
PHX_SERVER=true MIX_ENV=test PORT=4000 mix phx.server >>"$ROOT/phx.log" 2>&1 &
PHX_PID=$!
for i in $(seq 1 30); do
  curl -sf http://localhost:4000/ >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://localhost:4000/ >/dev/null || { echo "phx server did not boot"; tail -20 "$ROOT/phx.log"; exit 1; }

# --- two clothesline buses (their own CLI, env-configured) ---
start_bus() { # dir port
  (cd "$1" && env CLOTHESLINE_DATA_DIR="$1" CLOTHESLINE_PORT="$2" \
     "$CL/.venv/bin/python" -m clothesline.cli serve >>"$1/bus.log" 2>&1 &)
}
say "starting bus A on :19004"
start_bus "$A_DIR" 19004
say "starting bus B on :19005"
start_bus "$B_DIR" 19005
for port in 19004 19005; do
  for i in $(seq 1 30); do curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 1; done
  curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "bus :$port did not boot"; tail -20 "$ROOT/bus.log"; exit 1; }
done


say "running e2e assertions"
CLOTHESPIN_URL=http://localhost:4000 \
BUS_A_URL=http://127.0.0.1:19004/mcp \
BUS_B_URL=http://127.0.0.1:19005/mcp \
  python3 scripts/e2e_mcp.py 2>&1 | tee -a "$LOG"
