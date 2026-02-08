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
#   ./pull_and_run.sh                  # default: pull + restart in prod mode
#   ./pull_and_run.sh start
#   ./pull_and_run.sh stop
#   ./pull_and_run.sh restart
#   ./pull_and_run.sh update
#   ./pull_and_run.sh status
#   ./pull_and_run.sh logs
#
# Env knobs:
#   MODE=dev|prod        (default: prod)
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
#   CORS_ALLOW_ORIGIN=""  (optional)
#                        if empty in dev mode, this script auto-builds a LAN-safe origin list

MODE="${MODE:-prod}"
HOST="${HOST:-0.0.0.0}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
PYTHON="${PYTHON:-python3.12}"
DATA_DIR="${DATA_DIR:-}"
FOLLOW_LOGS="${FOLLOW_LOGS:-0}"
NPM_LEGACY_PEER_DEPS="${NPM_LEGACY_PEER_DEPS:-auto}"
UNBIND_PORTS="${UNBIND_PORTS:-0}"
CORS_ALLOW_ORIGIN="${CORS_ALLOW_ORIGIN:-}"

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

append_origin() {
  local current="$1"
  local candidate="$2"
  [[ -n "$candidate" ]] || {
    printf "%s" "$current"
    return 0
  }

  if [[ -z "$current" ]]; then
    printf "%s" "$candidate"
    return 0
  fi

  case ";$current;" in
    *";$candidate;"*) printf "%s" "$current" ;;
    *) printf "%s;%s" "$current" "$candidate" ;;
  esac
}

detect_primary_ipv4() {
  local ip=""

  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
  fi

  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  if [[ -z "$ip" ]] && command -v ifconfig >/dev/null 2>&1; then
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
  fi

  printf "%s" "$ip"
}

build_dev_cors_allow_origin() {
  local origins=""

  origins="$(append_origin "$origins" "http://localhost:$FRONTEND_PORT")"
  origins="$(append_origin "$origins" "http://127.0.0.1:$FRONTEND_PORT")"
  origins="$(append_origin "$origins" "http://localhost:$BACKEND_PORT")"
  origins="$(append_origin "$origins" "http://127.0.0.1:$BACKEND_PORT")"

  if [[ "$HOST" != "0.0.0.0" && "$HOST" != "::" && "$HOST" != "localhost" ]]; then
    origins="$(append_origin "$origins" "http://$HOST:$FRONTEND_PORT")"
    origins="$(append_origin "$origins" "http://$HOST:$BACKEND_PORT")"
  fi

  local detected_ip
  detected_ip="$(detect_primary_ipv4)"
  if [[ -n "$detected_ip" ]]; then
    origins="$(append_origin "$origins" "http://$detected_ip:$FRONTEND_PORT")"
    origins="$(append_origin "$origins" "http://$detected_ip:$BACKEND_PORT")"
  fi

  printf "%s" "$origins"
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

  if [[ "$MODE" == "dev" ]]; then
    local effective_cors_allow_origin
    if [[ -n "$CORS_ALLOW_ORIGIN" ]]; then
      effective_cors_allow_origin="$CORS_ALLOW_ORIGIN"
    else
      effective_cors_allow_origin="$(build_dev_cors_allow_origin)"
    fi

    say "Backend mode: dev (uvicorn --reload)"
    say "CORS_ALLOW_ORIGIN=$effective_cors_allow_origin"
    (
      cd "$BACKEND_DIR"
      launch_detached "Backend" "$BACKEND_PID" "$BACKEND_LOG" \
        env PYTHONUNBUFFERED=1 CORS_ALLOW_ORIGIN="$effective_cors_allow_origin" \
        uvicorn open_webui.main:app --port "$BACKEND_PORT" --host "$HOST" --forwarded-allow-ips "*" --reload
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

  if [[ "$MODE" == "prod" ]]; then
    # Backend mounts SPA files only if FRONTEND_BUILD_DIR exists at startup.
    # Build frontend first so backend serves UI immediately instead of API-only.
    start_frontend
    start_backend
  else
    start_backend
    start_frontend
  fi
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

cmd="${1:-update}"
case "$cmd" in
  run)     update_repo; restart ;;
  start)   start ;;
  stop)    stop ;;
  restart) restart ;;
  update)  update_repo; restart ;;
  status)  status ;;
  logs)    logs ;;
  *)
    say "Unknown command: $cmd"
    say "Usage: $0 {run|start|stop|restart|update|status|logs}"
    exit 1
    ;;
esac
