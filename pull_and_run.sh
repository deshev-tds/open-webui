#!/usr/bin/env bash
set -euo pipefail

# openwebui-runner.sh
# Update + (re)start Open WebUI from source, WITHOUT swallowing output.
# - Streams stdout/stderr live to your terminal
# - Also tees everything into .run/*.log
# - Tracks PIDs in .run/*.pid
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
#   HOST=0.0.0.0         (default: 0.0.0.0)  # bind for LAN access
#   BACKEND_PORT=8080    (default: 8080)
#   FRONTEND_PORT=5173   (default: 5173)     # only used in dev
#   PYTHON=python3.12    (default: python3.12)
#   DATA_DIR=""          (optional; exported for backend, if your Open WebUI honors it)

MODE="${MODE:-dev}"
HOST="${HOST:-0.0.0.0}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
PYTHON="${PYTHON:-python3.12}"
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

    for _ in {1..30}; do
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

update_repo() {
  require_cmd git
  say "Updating repo (fast-forward only)…"
  ( cd "$ROOT_DIR" && git diff-index --quiet HEAD -- ) || {
    say "Working tree has local changes. Commit/stash first. Aborting update."
    exit 2
  }
  ( cd "$ROOT_DIR" && git pull --ff-only )
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

  say "Upgrading pip/wheel/setuptools…"
  python -m pip install -U pip wheel setuptools

  say "Installing backend requirements…"
  python -m pip install -r "$BACKEND_DIR/requirements.txt"

  if [[ -n "$DATA_DIR" ]]; then
    export DATA_DIR
    say "DATA_DIR=$DATA_DIR"
  fi

  : > "$BACKEND_LOG"

  if [[ "$MODE" == "dev" && -f "$BACKEND_DIR/dev.sh" ]]; then
    say "Backend mode: dev (backend/dev.sh)"
    (
      cd "$BACKEND_DIR"
      exec bash -lc "sh dev.sh"
    ) > >(tee -a "$BACKEND_LOG") 2> >(tee -a "$BACKEND_LOG" >&2) &
    echo $! > "$BACKEND_PID"
  else
    say "Backend mode: prod-ish (uvicorn open_webui.main:app)"
    (
      cd "$BACKEND_DIR"
      exec uvicorn open_webui.main:app --host "$HOST" --port "$BACKEND_PORT"
    ) > >(tee -a "$BACKEND_LOG") 2> >(tee -a "$BACKEND_LOG" >&2) &
    echo $! > "$BACKEND_PID"
  fi

  say "Backend PID: $(cat "$BACKEND_PID")"
  say "Backend log: $BACKEND_LOG"
}

start_frontend() {
  say "Starting frontend…"
  require_cmd npm

  if [[ -f "$ROOT_DIR/package-lock.json" ]]; then
    say "npm ci"
    ( cd "$ROOT_DIR" && npm ci )
  else
    say "npm install"
    ( cd "$ROOT_DIR" && npm install )
  fi

  : > "$FRONTEND_LOG"

  if [[ "$MODE" == "dev" ]]; then
    say "Frontend mode: dev (npm run dev)"
    (
      cd "$ROOT_DIR"
      exec npm run dev -- --host "$HOST" --port "$FRONTEND_PORT"
    ) > >(tee -a "$FRONTEND_LOG") 2> >(tee -a "$FRONTEND_LOG" >&2) &
    echo $! > "$FRONTEND_PID"

    say "Frontend PID: $(cat "$FRONTEND_PID")"
    say "Frontend log: $FRONTEND_LOG"
  else
    say "Frontend mode: prod (npm run build; no separate dev server)"
    ( cd "$ROOT_DIR" && npm run build ) > >(tee -a "$FRONTEND_LOG") 2> >(tee -a "$FRONTEND_LOG" >&2)
    say "Frontend built. In prod mode, backend should serve built assets (depending on your Open WebUI version)."
  fi
}

status() {
  if is_running_pidfile "$BACKEND_PID"; then
    say "Backend:  RUNNING (PID $(cat "$BACKEND_PID"))"
  else
    say "Backend:  STOPPED"
  fi

  if is_running_pidfile "$FRONTEND_PID"; then
    say "Frontend: RUNNING (PID $(cat "$FRONTEND_PID"))"
  else
    if [[ "$MODE" == "prod" ]]; then
      say "Frontend: (prod) built + served by backend (no separate process)"
    else
      say "Frontend: STOPPED"
    fi
  fi

  say "Bind:"
  say "  HOST=$HOST"
  say "Ports:"
  say "  BACKEND_PORT=$BACKEND_PORT"
  say "  FRONTEND_PORT=$FRONTEND_PORT"

  say "URLs:"
  if [[ "$MODE" == "dev" ]]; then
    say "  UI:  http://$HOST:$FRONTEND_PORT"
    say "  API: http://$HOST:$BACKEND_PORT"
  else
    say "  UI/API: http://$HOST:$BACKEND_PORT"
  fi

  say "Logs:"
  say "  $BACKEND_LOG"
  say "  $FRONTEND_LOG"
}

start() {
  if is_running_pidfile "$BACKEND_PID" || is_running_pidfile "$FRONTEND_PID"; then
    say "Already running (or partially). Use: $0 restart"
    exit 0
  fi
  start_backend
  start_frontend
  status
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