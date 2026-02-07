#!/usr/bin/env bash
set -euo pipefail

# pull_and_run.sh
# Update + (re)start Open WebUI from source, WITHOUT swallowing output.
# - Setup/update output streams live to your terminal
# - Runtime output is written fully into .run/*.log
# - `logs` command follows logs live when needed
# - Tracks PIDs in .run/*.pid
#
# Usage:
#   ./pull_and_run.sh start
#   ./pull_and_run.sh stop
#   ./pull_and_run.sh restart
#   ./pull_and_run.sh update
#   ./pull_and_run.sh status
#   ./pull_and_run.sh logs
#
# Env knobs:
#   MODE=dev|prod        (default: dev)
#   HOST=0.0.0.0         (default: 0.0.0.0)  # bind for LAN access
#   BACKEND_PORT=8080    (default: 8080)
#   FRONTEND_PORT=5173   (default: 5173)     # only used in dev
#   PYTHON=python3.12    (default: python3.12)
#   DATA_DIR=""          (optional; exported for backend, if your Open WebUI honors it)
#   FOLLOW_LOGS=0|1      (default: 0)        # 1 => auto-follow logs after `start`
#   NPM_LEGACY_PEER_DEPS=auto|0|1 (default: auto)
#                        auto => retry npm ci with --legacy-peer-deps on ERESOLVE
#                        1    => always run npm ci --legacy-peer-deps
#   UNBIND_PORTS=0|1      (default: 0)
#                        1 => before start, stop any process listening on configured ports

MODE="${MODE:-dev}"
HOST="${HOST:-0.0.0.0}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
PYTHON="${PYTHON:-python3.12}"
DATA_DIR="${DATA_DIR:-}"
FOLLOW_LOGS="${FOLLOW_LOGS:-0}"
NPM_LEGACY_PEER_DEPS="${NPM_LEGACY_PEER_DEPS:-auto}"
UNBIND_PORTS="${UNBIND_PORTS:-0}"

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

listening_pids_on_port() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnp "sport = :$port" 2>/dev/null \
      | sed -nE 's/.*pid=([0-9]+).*/\1/p' \
      | sort -u
    return 0
  fi

  if command -v fuser >/dev/null 2>&1; then
    fuser -n tcp "$port" 2>/dev/null | tr ' ' '\n' | awk 'NF' | sort -u
    return 0
  fi

  say "Port inspection requires one of: lsof, ss, fuser"
  exit 1
}

print_pid_details() {
  local pid_list="$1"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    local details
    details="$(ps -p "$pid" -o user=,pid=,comm=,args= 2>/dev/null || true)"
    if [[ -n "$details" ]]; then
      say "  $details"
    else
      say "  PID $pid (details unavailable)"
    fi
  done <<< "$pid_list"
}

kill_pid_list() {
  local pid_list="$1"

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done <<< "$pid_list"

  for _ in {1..25}; do
    local any_alive=0
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if kill -0 "$pid" 2>/dev/null; then
        any_alive=1
        break
      fi
    done <<< "$pid_list"
    [[ "$any_alive" == "0" ]] && return 0
    sleep 0.2
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done <<< "$pid_list"
}

ensure_port_is_free() {
  local name="$1"
  local port="$2"
  local pid_list
  pid_list="$(listening_pids_on_port "$port" || true)"
  [[ -n "$pid_list" ]] || return 0

  say "$name port :$port is already in use by:"
  print_pid_details "$pid_list"

  if [[ "$UNBIND_PORTS" == "1" ]]; then
    say "UNBIND_PORTS=1: stopping listeners on :$port…"
    kill_pid_list "$pid_list"
    sleep 0.2
    local remaining
    remaining="$(listening_pids_on_port "$port" || true)"
    if [[ -n "$remaining" ]]; then
      say "Could not free :$port. Remaining listeners:"
      print_pid_details "$remaining"
      exit 1
    fi
    say "Port :$port is now free."
  else
    say "Set UNBIND_PORTS=1 to auto-stop listeners, or stop them manually."
    exit 1
  fi
}

launch_detached() {
  local name="$1"
  local pidfile="$2"
  local logfile="$3"
  shift 3

  : > "$logfile"

  # nohup decouples runtime services from the controlling terminal (survives SSH/session close).
  nohup "$@" >>"$logfile" 2>&1 < /dev/null &
  local pid=$!
  echo "$pid" > "$pidfile"

  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    say "Failed to start $name. Recent log output:"
    tail -n 120 "$logfile" || true
    rm -f "$pidfile"
    exit 1
  fi

  say "$name PID: $pid"
  say "$name log: $logfile"
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

  if [[ "$MODE" == "dev" && -f "$BACKEND_DIR/dev.sh" ]]; then
    say "Backend mode: dev (backend/dev.sh)"
    (
      cd "$BACKEND_DIR"
      launch_detached "Backend" "$BACKEND_PID" "$BACKEND_LOG" env PYTHONUNBUFFERED=1 sh dev.sh
    )
  else
    say "Backend mode: prod-ish (uvicorn open_webui.main:app)"
    (
      cd "$BACKEND_DIR"
      launch_detached "Backend" "$BACKEND_PID" "$BACKEND_LOG" \
        env PYTHONUNBUFFERED=1 uvicorn open_webui.main:app --host "$HOST" --port "$BACKEND_PORT"
    )
  fi
}

start_frontend() {
  say "Starting frontend…"
  require_cmd npm

  if [[ -f "$ROOT_DIR/package-lock.json" ]]; then
    if [[ "$NPM_LEGACY_PEER_DEPS" == "1" ]]; then
      say "npm ci --legacy-peer-deps"
      ( cd "$ROOT_DIR" && npm ci --legacy-peer-deps )
    else
      say "npm ci"
      if ! ( cd "$ROOT_DIR" && npm ci ); then
        if [[ "$NPM_LEGACY_PEER_DEPS" == "auto" ]]; then
          say "npm ci failed; retrying with --legacy-peer-deps due dependency resolution conflict…"
          ( cd "$ROOT_DIR" && npm ci --legacy-peer-deps )
        else
          exit 1
        fi
      fi
    fi
  else
    say "npm install"
    ( cd "$ROOT_DIR" && npm install )
  fi

  if [[ "$MODE" == "dev" ]]; then
    say "Frontend mode: dev (npm run dev)"
    (
      cd "$ROOT_DIR"
      launch_detached "Frontend" "$FRONTEND_PID" "$FRONTEND_LOG" \
        npm run dev -- --host "$HOST" --port "$FRONTEND_PORT"
    )
  else
    say "Frontend mode: prod (npm run build; no separate dev server)"
    : > "$FRONTEND_LOG"
    ( cd "$ROOT_DIR" && npm run build ) >>"$FRONTEND_LOG" 2>&1
    say "Frontend build log: $FRONTEND_LOG"
    say "Frontend built. In prod mode, backend should serve built assets (depending on your Open WebUI version)."
  fi
}

logs() {
  require_cmd tail
  [[ -f "$BACKEND_LOG" ]] || touch "$BACKEND_LOG"
  [[ -f "$FRONTEND_LOG" ]] || touch "$FRONTEND_LOG"

  if [[ "$MODE" == "prod" ]]; then
    say "Following backend log (Ctrl-C to stop)…"
    tail -n 200 -F "$BACKEND_LOG"
  else
    say "Following backend + frontend logs (Ctrl-C to stop)…"
    tail -n 200 -F "$BACKEND_LOG" "$FRONTEND_LOG"
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

  ensure_port_is_free "Backend" "$BACKEND_PORT"
  if [[ "$MODE" == "dev" ]]; then
    ensure_port_is_free "Frontend" "$FRONTEND_PORT"
  fi

  start_backend
  start_frontend
  status
  if [[ "$FOLLOW_LOGS" == "1" ]]; then
    logs
  else
    say "Tip: run '$0 logs' to stream runtime output."
  fi
}

stop() {
  stop_one "frontend" "$FRONTEND_PID"
  stop_one "backend" "$BACKEND_PID"

  if [[ "$UNBIND_PORTS" == "1" ]]; then
    ensure_port_is_free "Backend" "$BACKEND_PORT"
    if [[ "$MODE" == "dev" ]]; then
      ensure_port_is_free "Frontend" "$FRONTEND_PORT"
    fi
  fi
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
  logs)    logs ;;
  *)
    say "Unknown command: $cmd"
    say "Usage: $0 {start|stop|restart|update|status|logs}"
    exit 1
    ;;
esac
