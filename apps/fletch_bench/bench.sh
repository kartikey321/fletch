#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fletch HTTP transport benchmark — 4-way comparison
#
#   dart:io (single)  vs  dart:io + isolates
#   NativeHttpServer  vs  NativeHttpServer + isolates
#
# Prerequisites:
#   - wrk  (brew install wrk)
#   - dart (on PATH)
#
# Usage:
#   ./bench.sh [options]
#
# Options:
#   -t <n>   wrk threads      (default: 4)
#   -c <n>   connections      (default: 100)
#   -d <s>   benchmark dur    (default: 30s)
#   -p <n>   base port        (default: 8080)
#   -w <s>   warmup duration  (default: 5s)
#   -s       skip single-isolate runs (only run multi-isolate)
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
THREADS=4
CONNECTIONS=100
DURATION=30s
WARMUP=5s
PORT=0     # 0 = OS picks a free ephemeral port
SKIP_SINGLE=false
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while getopts "t:c:d:p:w:s" opt; do
  case $opt in
    t) THREADS="$OPTARG" ;;
    c) CONNECTIONS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    w) WARMUP="$OPTARG" ;;
    s) SKIP_SINGLE=true ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# ── Dependency checks ────────────────────────────────────────────────────────
if ! command -v wrk &>/dev/null; then
  echo "❌  wrk not found. Install: brew install wrk" >&2; exit 1
fi
if ! command -v dart &>/dev/null; then
  echo "❌  dart not found. Install the Dart SDK first." >&2; exit 1
fi

# ── Colours ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; DIM='\033[2m'; RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

wait_for_ready() {       # wait_for_ready <pid> <logfile> → prints port
  local pid=$1 log=$2
  local deadline=$(( $(date +%s) + 20 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo -e "${YELLOW}❌  Server (PID $pid) died early:${RESET}" >&2
      cat "$log" >&2; exit 1
    fi
    if grep -q "^READY" "$log" 2>/dev/null; then
      grep "^READY" "$log" | head -1 | grep -o 'port=[0-9]*' | cut -d= -f2
      return
    fi
    sleep 0.2
  done
  echo "❌  Server did not become ready within 20s. Log:" >&2
  cat "$log" >&2
  kill "$pid" 2>/dev/null || true; exit 1
}

run_wrk() {              # run_wrk <url> <outfile>
  local url=$1 out=$2
  echo -e "${DIM}    warmup (${WARMUP})...${RESET}"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$WARMUP" "$url" &>/dev/null
  echo -e "${DIM}    measuring (${DURATION})...${RESET}"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "$url" >"$out" 2>&1
}

parse_rps() { grep -E "Requests/sec:" "$1" | awk '{gsub(/,/,""); print $2}'; }

parse_lat() {            # parse_lat <file> <percentile>
  grep -E "^\s+${2}%" "$1" | awk '{print $2}'
}

to_ms() {                # normalise wrk latency string → ms (3 d.p.)
  echo "$1" | awk '{
    v=$0
    if      (sub(/us$/, "", v)) { printf "%.3f", v/1000 }
    else if (sub(/ms$/, "", v)) { printf "%.3f", v }
    else if (sub(/s$/,  "", v)) { printf "%.3f", v*1000 }
    else                        { print v }
  }'
}

pct_change() {           # pct_change <baseline> <value> → "+12.3%" or "-5.6%"
  echo "$1 $2" | awk '{
    if ($1==0) { print "N/A"; next }
    printf "%+.1f%%", ($2-$1)/$1*100
  }'
}

# benchmark_server <label> <exe> <wrk_outfile>
benchmark_server() {
  local label=$1 exe=$2 wrkout=$3
  local srvlog; srvlog="$(mktemp)"

  echo -e "\n${BOLD}━━━ ${label} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

  "$exe" "$PORT" >"$srvlog" 2>&1 &
  local pid=$!

  local actual_port; actual_port=$(wait_for_ready "$pid" "$srvlog")
  local workers; workers=$(grep "^READY" "$srvlog" | grep -o 'workers=[0-9]*' | cut -d= -f2 || echo 1)
  echo -e "  PID ${pid}  port ${actual_port}  workers ${workers}"

  run_wrk "http://localhost:${actual_port}/bench" "$wrkout"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$srvlog"
}

# ── pub get ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Fetching dependencies...${RESET}"
(cd "$BENCH_DIR" && dart pub get 2>&1 | grep -v "^$" | grep -E "^(Resolving|Downloading|Got|Changed|No)" || true)

# ── Temp dir ─────────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WRK_DARTIO="$TMP/dartio.txt"
WRK_DARTIO_ISO="$TMP/dartio_iso.txt"
WRK_NATIVE="$TMP/native.txt"
WRK_NATIVE_ISO="$TMP/native_iso.txt"

# ── Build all servers with dart build cli (supports native build hooks) ───────
# Output: <TMP>/<name>/bundle/bin/<name>  +  bundle/lib/*.dylib
NCPUS=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo "?")
echo -e "\n${BOLD}Building servers (dart build cli)...${RESET}"
echo -e "${DIM}  AOT + native assets — first run compiles Rust, subsequent builds use cache${RESET}"

# Pre-compute exe paths — dart build cli always writes to <outdir>/bundle/bin/<stem>
EXE_DARTIO="$TMP/dartio/bundle/bin/server_dart_io"
EXE_NATIVE="$TMP/native/bundle/bin/server_native"
EXE_DARTIO_ISO="$TMP/dartio_iso/bundle/bin/server_dart_io_isolates"
EXE_NATIVE_ISO="$TMP/native_iso/bundle/bin/server_native_isolates"

build_server() {    # build_server <bin/script.dart> <outdir>
  local src=$1 outdir=$2
  echo -e "${DIM}  dart build cli -t $src${RESET}"
  (cd "$BENCH_DIR" && dart build cli -t "$src" -o "$outdir" \
    --verbosity=error) 2>&1 || true
}

if [[ "$SKIP_SINGLE" == false ]]; then
  build_server "bin/server_dart_io.dart"          "$TMP/dartio"
  build_server "bin/server_native.dart"           "$TMP/native"
fi
build_server "bin/server_dart_io_isolates.dart"   "$TMP/dartio_iso"
build_server "bin/server_native_isolates.dart"    "$TMP/native_iso"

echo ""

# ── Run benchmarks ────────────────────────────────────────────────────────────
if [[ "$SKIP_SINGLE" == false ]]; then
  benchmark_server "dart:io  (single isolate)"          "$EXE_DARTIO"     "$WRK_DARTIO"
  benchmark_server "NativeHttpServer  (single isolate)" "$EXE_NATIVE"     "$WRK_NATIVE"
fi

benchmark_server "dart:io  (${NCPUS} isolates)"          "$EXE_DARTIO_ISO" "$WRK_DARTIO_ISO"
benchmark_server "NativeHttpServer  (${NCPUS} isolates)"  "$EXE_NATIVE_ISO" "$WRK_NATIVE_ISO"

# ── Parse all results ─────────────────────────────────────────────────────────
get_stats() {          # get_stats <wrkfile> → sets RPS P50 P75 P90 P99
  local f=$1
  RPS=$(parse_rps "$f")
  P50=$(to_ms "$(parse_lat "$f" 50)")
  P75=$(to_ms "$(parse_lat "$f" 75)")
  P90=$(to_ms "$(parse_lat "$f" 90)")
  P99=$(to_ms "$(parse_lat "$f" 99)")
}

if [[ "$SKIP_SINGLE" == false ]]; then
  get_stats "$WRK_DARTIO";     DIO_RPS=$RPS; DIO_P50=$P50; DIO_P75=$P75; DIO_P90=$P90; DIO_P99=$P99
  get_stats "$WRK_NATIVE";     NAT_RPS=$RPS; NAT_P50=$P50; NAT_P75=$P75; NAT_P90=$P90; NAT_P99=$P99
fi

get_stats "$WRK_DARTIO_ISO";   DII_RPS=$RPS; DII_P50=$P50; DII_P75=$P75; DII_P90=$P90; DII_P99=$P99
get_stats "$WRK_NATIVE_ISO";   NII_RPS=$RPS; NII_P50=$P50; NII_P75=$P75; NII_P90=$P90; NII_P99=$P99

# ── Summary table ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━ Results ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  wrk: -t${THREADS} -c${CONNECTIONS} -d${DURATION} --latency  •  CPUs: ${NCPUS}"
echo -e "  Endpoint: GET /bench → {\"ok\":true}\n"

if [[ "$SKIP_SINGLE" == false ]]; then
  printf "  ${BOLD}%-22s %12s %12s %12s %12s${RESET}\n" \
    "Metric" "dart:io" "dart:io+iso" "native" "native+iso"
  printf "  %-22s %12s %12s %12s %12s\n" \
    "──────────────────────" "────────────" "────────────" "────────────" "────────────"

  printf "  %-22s %12s %12s %12s %12s\n" \
    "Throughput (req/s)" "$DIO_RPS" "$DII_RPS" "$NAT_RPS" "$NII_RPS"
  printf "  %-22s %12s %12s %12s %12s\n" \
    "Latency p50 (ms)"   "$DIO_P50" "$DII_P50" "$NAT_P50" "$NII_P50"
  printf "  %-22s %12s %12s %12s %12s\n" \
    "Latency p75 (ms)"   "$DIO_P75" "$DII_P75" "$NAT_P75" "$NII_P75"
  printf "  %-22s %12s %12s %12s %12s\n" \
    "Latency p90 (ms)"   "$DIO_P90" "$DII_P90" "$NAT_P90" "$NII_P90"
  printf "  %-22s %12s %12s %12s %12s\n" \
    "Latency p99 (ms)"   "$DIO_P99" "$DII_P99" "$NAT_P99" "$NII_P99"

  echo ""
  printf "  ${BOLD}%-22s %12s %12s %12s${RESET}\n" \
    "vs dart:io baseline" "dart:io" "dart:io+iso" "native"
  printf "  %-22s %12s %12s %12s\n" \
    "──────────────────────" "────────────" "────────────" "────────────"
  printf "  %-22s %12s %12s %12s\n" "Throughput Δ" \
    "—" "$(pct_change "$DIO_RPS" "$DII_RPS")" "$(pct_change "$DIO_RPS" "$NAT_RPS")"
  printf "  %-22s %12s %12s %12s\n" "p50 Δ" \
    "—" "$(pct_change "$DIO_P50" "$DII_P50")" "$(pct_change "$DIO_P50" "$NAT_P50")"
  printf "  %-22s %12s %12s %12s\n" "p99 Δ" \
    "—" "$(pct_change "$DIO_P99" "$DII_P99")" "$(pct_change "$DIO_P99" "$NAT_P99")"

  echo ""
  # Find the overall winner
  ALL_RPS=("$DIO_RPS" "$DII_RPS" "$NAT_RPS" "$NII_RPS")
  ALL_LABELS=("dart:io" "dart:io+isolates" "native" "native+isolates")
  WINNER_IDX=$(echo "${ALL_RPS[@]}" | tr ' ' '\n' | awk 'BEGIN{max=0;idx=0} {if($1>max){max=$1;idx=NR-1}} END{print idx}')
  echo -e "  ${GREEN}${BOLD}Winner: ${ALL_LABELS[$WINNER_IDX]} (${ALL_RPS[$WINNER_IDX]} req/s)${RESET}"
else
  # Isolates-only table
  printf "  ${BOLD}%-22s %14s %14s %10s${RESET}\n" \
    "Metric" "dart:io+iso" "native+iso" "Δ"
  printf "  %-22s %14s %14s %10s\n" \
    "──────────────────────" "──────────────" "──────────────" "──────────"
  printf "  %-22s %14s %14s %10s\n" \
    "Throughput (req/s)" "$DII_RPS" "$NII_RPS" "$(pct_change "$DII_RPS" "$NII_RPS")"
  printf "  %-22s %14s %14s %10s\n" \
    "Latency p50 (ms)"   "$DII_P50" "$NII_P50" "$(pct_change "$DII_P50" "$NII_P50")"
  printf "  %-22s %14s %14s %10s\n" \
    "Latency p75 (ms)"   "$DII_P75" "$NII_P75" "$(pct_change "$DII_P75" "$NII_P75")"
  printf "  %-22s %14s %14s %10s\n" \
    "Latency p90 (ms)"   "$DII_P90" "$NII_P90" "$(pct_change "$DII_P90" "$NII_P90")"
  printf "  %-22s %14s %14s %10s\n" \
    "Latency p99 (ms)"   "$DII_P99" "$NII_P99" "$(pct_change "$DII_P99" "$NII_P99")"
fi

echo ""
