#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config (override via env vars)
# ----------------------------
BASE_URL="${BASE_URL:-http://192.168.1.117:1234}"
BASE_URL="${BASE_URL%/}"            # tolerate trailing slash in BASE_URL
MODEL="${MODEL:-whatever}"
N="${N:-3}"                        # how many repeats for each scenario
PROMPT_FILE="${PROMPT_FILE:-}"     # optional: file with long system prompt
SYSTEM_LEN_KB="${SYSTEM_LEN_KB:-512}"  # if no PROMPT_FILE: generate ~KB system prompt
USER_1="${USER_1:-Hello}"
USER_2="${USER_2:-Find the bug in line 42}"  # same prefix, different user question
TIMEOUT="${TIMEOUT:-600}"          # curl max-time seconds
OUT_DIR="${OUT_DIR:-./prompt_cache_test_out}"
MAX_TOKENS="${MAX_TOKENS:-64}"     # keep completion short to emphasize prompt processing
TEMPERATURE="${TEMPERATURE:-0}"    # deterministic generation
SEED="${SEED:-42}"                 # deterministic generation (llama.cpp supports this)

mkdir -p "$OUT_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need python3
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; else HAS_JQ=0; fi

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Create / load a "long" system prompt
make_system_prompt() {
  if [[ -n "$PROMPT_FILE" ]]; then
    cat "$PROMPT_FILE"
    return
  fi

  # Generate ~SYSTEM_LEN_KB KB of deterministic text (same every run)
  python3 - <<'PY'
import os, textwrap, hashlib
kb = int(os.environ.get("SYSTEM_LEN_KB","512"))
target = kb * 1024
seed = b"prompt-cache-test-seed-v1"
chunk = (b"System policy block. " * 64) + b"\n"
buf = bytearray()
i = 0
while len(buf) < target:
    h = hashlib.sha256(seed + str(i).encode()).hexdigest()
    buf.extend((h + "\n").encode())
    buf.extend(chunk)
    i += 1
print(buf[:target].decode("utf-8", errors="ignore"))
PY
}

SYSTEM_PROMPT="$(make_system_prompt)"

# JSON escape via python (so we don't rely on jq for that)
json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

if ! SYSTEM_JSON="$(printf "%s" "$SYSTEM_PROMPT" | json_escape)"; then
  echo "Failed to JSON-escape system prompt." >&2
  exit 1
fi

# Build payload helper
payload() {
  local cache_prompt="$1"
  local user="$2"

  cat <<JSON
{
  "model": "$MODEL",
  "stream": false,
  "max_tokens": $MAX_TOKENS,
  "temperature": $TEMPERATURE,
  "seed": $SEED,
  "cache_prompt": $cache_prompt,
  "messages": [
    {"role": "system", "content": ${SYSTEM_JSON}},
    {"role": "user", "content": $(printf "%s" "$user" | json_escape)}
  ]
}
JSON
}

# Measure one request end-to-end time in seconds (high precision)
run_one() {
  local name="$1"
  local cache_prompt="$2"
  local user="$3"
  local idx="$4"

  local req_file="$OUT_DIR/${name}_req_${idx}.json"
  local resp_file="$OUT_DIR/${name}_resp_${idx}.json"

  payload "$cache_prompt" "$user" > "$req_file"

  # Use curl's total_time for accurate wall clock (includes network + server time)
  # Save body for inspection and hard-fail on request/HTTP errors.
  local curl_time
  local http_code
  local curl_meta
  if ! curl_meta="$(curl -sS --fail-with-body \
    --max-time "$TIMEOUT" \
    -H 'Content-Type: application/json' \
    -o "$resp_file" \
    -w '%{http_code}\t%{time_total}' \
    "$BASE_URL/v1/chat/completions" \
    -d @"$req_file")"; then
    echo "Request failed for $name #$idx (see $resp_file)." >&2
    return 1
  fi
  IFS=$'\t' read -r http_code curl_time <<<"$curl_meta"
  if [[ "$http_code" != "200" ]]; then
    echo "Unexpected HTTP status $http_code for $name #$idx (see $resp_file)." >&2
    return 1
  fi

  if [[ $HAS_JQ -eq 1 ]]; then
    local api_error
    api_error="$(jq -r '.error.message // empty' "$resp_file" 2>/dev/null || true)"
    if [[ -n "$api_error" ]]; then
      echo "API returned error for $name #$idx: $api_error" >&2
      return 1
    fi
  fi

  # Try to extract server usage stats if present (llama.cpp often includes usage/prompt tokens)
  local prompt_tokens="-"
  local completion_tokens="-"
  local total_tokens="-"
  local cached_tokens="-"
  local prompt_ms="-"

  if [[ $HAS_JQ -eq 1 ]]; then
    prompt_tokens="$(jq -r '.usage.prompt_tokens // "-" ' "$resp_file" 2>/dev/null || echo "-")"
    completion_tokens="$(jq -r '.usage.completion_tokens // "-" ' "$resp_file" 2>/dev/null || echo "-")"
    total_tokens="$(jq -r '.usage.total_tokens // "-" ' "$resp_file" 2>/dev/null || echo "-")"
    cached_tokens="$(jq -r '.usage.prompt_tokens_details.cached_tokens // .usage.cached_tokens // "-" ' "$resp_file" 2>/dev/null || echo "-")"
    prompt_ms="$(jq -r '.timings.prompt_ms // "-" ' "$resp_file" 2>/dev/null || echo "-")"
  fi

  printf "%s\tcache=%s\t%.3fs\tprompt=%s\tcompletion=%s\ttotal=%s\tcached=%s\tprompt_ms=%s\n" \
    "$name" "$cache_prompt" "$curl_time" "$prompt_tokens" "$completion_tokens" "$total_tokens" "$cached_tokens" "$prompt_ms"
}

stats() {
  python3 -c '
import sys, statistics
raw = [x for x in sys.stdin.read().strip().split() if x]
vals = [float(x) for x in raw]
if not vals:
    print("n=0")
    raise SystemExit(0)
vals_sorted = sorted(vals)
def pct(p):
    k = (len(vals_sorted) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(vals_sorted) - 1)
    if f == c:
        return vals_sorted[f]
    return vals_sorted[f] * (c - k) + vals_sorted[c] * (k - f)
print(f"n={len(vals)} mean={statistics.mean(vals):.3f}s median={statistics.median(vals):.3f}s p90={pct(90):.3f}s min={min(vals):.3f}s max={max(vals):.3f}s")
'
}

echo "== prompt cache test =="
echo "time: $(timestamp)"
echo "base_url: $BASE_URL"
echo "model: $MODEL"
echo "repeats: $N"
echo "system prompt source: ${PROMPT_FILE:-generated ~${SYSTEM_LEN_KB}KB}"
echo "output dir: $OUT_DIR"
echo "generation: max_tokens=$MAX_TOKENS temperature=$TEMPERATURE seed=$SEED"
echo

# Four scenarios:
# A) cache_prompt=false first run
# B) cache_prompt=false second run (same prefix) -> should be similar
# C) cache_prompt=true first run
# D) cache_prompt=true second run (same prefix, different user)
#
# We do N repeats for each, printing per-run lines + aggregate stats.

declare -a A B C D
echo -e "scenario\tcache\twall_time\tprompt_tokens\tcompletion_tokens\ttotal_tokens\tcached_tokens\tprompt_ms"

for i in $(seq 1 "$N"); do
  if ! line="$(run_one "A_nocache_first" false "$USER_1" "$i")"; then
    echo "Scenario A_nocache_first failed at iteration $i." >&2
    exit 1
  fi
  echo "$line"
  A+=("$(printf "%s" "$line" | cut -f3 | sed 's/s$//')")
done

for i in $(seq 1 "$N"); do
  if ! line="$(run_one "B_nocache_repeat" false "$USER_2" "$i")"; then
    echo "Scenario B_nocache_repeat failed at iteration $i." >&2
    exit 1
  fi
  echo "$line"
  B+=("$(printf "%s" "$line" | cut -f3 | sed 's/s$//')")
done

for i in $(seq 1 "$N"); do
  if ! line="$(run_one "C_cache_first" true "$USER_1" "$i")"; then
    echo "Scenario C_cache_first failed at iteration $i." >&2
    exit 1
  fi
  echo "$line"
  C+=("$(printf "%s" "$line" | cut -f3 | sed 's/s$//')")
done

for i in $(seq 1 "$N"); do
  if ! line="$(run_one "D_cache_repeat" true "$USER_2" "$i")"; then
    echo "Scenario D_cache_repeat failed at iteration $i." >&2
    exit 1
  fi
  echo "$line"
  D+=("$(printf "%s" "$line" | cut -f3 | sed 's/s$//')")
done

echo
echo "== aggregate stats (wall time) =="
printf "%s\n" "${A[@]}" | stats | sed 's/^/A_nocache_first: /'
printf "%s\n" "${B[@]}" | stats | sed 's/^/B_nocache_repeat: /'
printf "%s\n" "${C[@]}" | stats | sed 's/^/C_cache_first: /'
printf "%s\n" "${D[@]}" | stats | sed 's/^/D_cache_repeat: /'

echo
echo "Interpretation:"
echo "- Primary signal: cache-enabled runs (C/D) should have lower prompt_ms and/or wall time than no-cache runs (A/B)."
echo "- On servers with aggressive slot reuse, C and D may both be similarly fast."
echo "- Without caching, B_nocache_repeat will look similar to A_nocache_first."
echo "- Inspect responses in: $OUT_DIR"
