#!/usr/bin/env bash
set -euo pipefail

# openwebui-runner.sh
# One-command update + restart for Open WebUI (frontend + backend) from source.
# Runs both processes in the background, writes PID + logs under .run/
#
# Usage:
#   ./openwebui-runner.sh start
#   ./openwebui-runner.sh stop
#   ./openwebui-runner.sh restart
#   ./openwebui-runner.sh update
#   ./openwebui-runner.sh status
#
# Env knobs:
#   MODE=dev|prod        (default: dev)
   HOST=0.0.0.0         (default: 127.0.0.1)
#   BACKEND_PORT=8080    (default: 8080)
#   FRONTEND_PORT=5173   (default: 5173)   # only used in dev
#   PYTHON=python3.12    (default: python3.12)
#   PIP_EXTRA=""         (default: "")
#   DATA_DIR=""          (optional, passed to backend if supported by your version)

MODE="${MODE:-dev}"
HOST="${HOST:-127.0.0.1}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
PYTHON="${PYTHON:-python3.12}"
PIP_EXTRA="${PIP_EXTRA:-}"
DATA_DIR="${DATA_DIR:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$ROOT_DIR/.run"
BACKEND_DIR="$ROOT_DIR/backend"
BACKEND_VENV="$BACKEND_DIR/.venv"

BACKEND_PID="$RUN_DIR/backend.pid"
FRONTEND_PID="$RUN_DIR/frontend.pid"
BACKEND_LOG="$RUN_DIR/backend.log"
FRONTEND_LOG="$RUN_DIR/frontend.log"

mkdir -p "$RUN_DIR"

say() { printf "%s\n" "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { say "Missing command: $1"; exit 1; }
}

is_running_pidfile() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 1
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "${pid:-}" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

stop_one() {
  local name="$1" pidfile="$2"
  if is_running_pidfile "$pidfile"; then
    local pid
    pid="$(cat "$pidfile")"
    say "Stopping $name (PID $pid)…"
    kill "$pid" 2>/dev/null || true

    # gentle wait, then hard kill if needed
    for _ in {1..20}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      say "$name still alive, sending SIGKILL…"
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    say "$name not running."
  fi
  rm -f "$pidfile"
}

start_backend() {
  say "Starting backend…"
  require_cmd "$PYTHON"

  if [[ ! -d "$BACKEND_VENV" ]]; then
    say "Creating backend venv: $BACKEND_VENV"
    ( cd "$BACKEND_DIR" && "$PYTHON" -m venv .venv )
  fi

  # shellcheck disable=SC1090
  source "$BACKEND_VENV/bin/activate"
  python -m pip install -U pip wheel setuptools >/dev/null
  python -m pip install -r "$BACKEND_DIR/requirements.txt" ${PIP_EXTRA} >/dev/null

  # Prefer repo-provided dev script if present (matches Open WebUI dev workflow)
  # Otherwise fall back to uvicorn module path (may vary across versions).
  local cmd
  if [[ "$MODE" == "dev" && -f "$BACKEND_DIR/dev.sh" ]]; then
    cmd=( bash -lc "cd '$BACKEND_DIR' && ${DATA_DIR:+DATA_DIR='$DATA_DIR'} sh dev.sh" )
  else
    # "prod-ish" fallback: assumes an ASGI app exists at open_webui.main:app
    cmd=( bash -lc "cd '$BACKEND_DIR' && ${DATA_DIR:+DATA_DIR='$DATA_DIR'} exec uvicorn open_webui.main:app --host '$HOST' --port '$BACKEND_PORT'" )
  fi

  # Start in background, capture PID
  nohup "${cmd[@]}" >"$BACKEND_LOG" 2>&1 & echo $! >"$BACKEND_PID"
  say "Backend PID: $(cat "$BACKEND_PID")  log: $BACKEND_LOG"
}

start_frontend() {
  say "Starting frontend…"
  require_cmd npm

  # Install deps (ci if lockfile exists)
  if [[ -f "$ROOT_DIR/package-lock.json" ]]; then
    ( cd "$ROOT_DIR" && npm ci --silent )
  else
    ( cd "$ROOT_DIR" && npm install --silent )
  fi

  local cmd
  if [[ "$MODE" == "dev" ]]; then
    # Vite default dev server
    cmd=( bash -lc "cd '$ROOT_DIR' && exec npm run dev -- --host '$HOST' --port '$FRONTEND_PORT'" )
  else
    # Build once, then rely on backend to serve, or serve static if you add a serve script
    ( cd "$ROOT_DIR" && npm run build --silent )
    say "Frontend built. (In prod mode, backend should serve the built assets in your Open WebUI version.)"
    return 0
  fi

  nohup "${cmd[@]}" >"$FRONTEND_LOG" 2>&1 & echo $! >"$FRONTEND_PID"
  say "Frontend PID: $(cat "$FRONTEND_PID")  log: $FRONTEND_LOG"
}

update_repo() {
  require_cmd git
  say "Updating repo (fast-forward only)…"

  # Refuse to pull if dirty to avoid surprise merges/conflicts
  ( cd "$ROOT_DIR" && git diff-index --quiet HEAD -- ) || {
    say "Working tree has local changes. Commit/stash first. Aborting update."
    exit 2
  }

  ( cd "$ROOT_DIR" && git pull --ff-only )
}

status() {
  if is_running_pidfile "$BACKEND_PID"; then
    say "Backend: RUNNING (PID $(cat "$BACKEND_PID"))"
  else
    say "Backend: STOPPED"
  fi

  if is_running_pidfile "$FRONTEND_PID"; then
    say "Frontend: RUNNING (PID $(cat "$FRONTEND_PID"))"
  else
    if [[ "$MODE" == "prod" ]]; then
      say "Frontend: (prod mode) built + served by backend (no separate process)"
    else
      say "Frontend: STOPPED"
    fi
  fi

  say "Logs:"
  say "  $BACKEND_LOG"
  say "  $FRONTEND_LOG"
}

start() {
  if is_running_pidfile "$BACKEND_PID" || is_running_pidfile "$FRONTEND_PID"; then
    say "Already running (or partially). Use ./openwebui-runner.sh restart"
    exit 0
  fi
  start_backend
  start_frontend

  if [[ "$MODE" == "dev" ]]; then
    say "UI: http://$HOST:$FRONTEND_PORT"
    say "API: http://$HOST:$BACKEND_PORT"
  else
    say "UI/API: http://$HOST:$BACKEND_PORT"
  fi
}

stop() {
  stop_one "frontend" "$FRONTEND_PID"
  stop_one "backend" "$BACKEND_PID"
}

restart() {
  stop || true
  start
}

cmd="${1:-status}"
case "$cmd" in
  start)   start ;;
  stop)    stop ;;
  restart) restart ;;
  update)  update_repo; restart ;;
  status)  status ;;
  *)
    say "Unknown command: $cmd"
    say "Usage: $0 {start|stop|restart|update|status}"
    exit 1
    ;;
esac