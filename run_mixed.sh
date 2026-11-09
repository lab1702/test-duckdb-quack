#!/usr/bin/env bash
# Admission-control test: light TPC-H queries mixed into a heavy load on a
# running DuckDB quack server (started with: ./start_server.sh), with a gate in
# front of the server that caps how many queries execute at once.
#
# run_tpch.sh answers "what happens with N queries in flight" for a closed
# batch of 22 queries, where every query is started as soon as a slot is free
# and the light queries (Q02, Q06, Q11, Q15) run last. It measures how long a
# light query takes to execute next to its neighbours, but not how long it
# would wait for a slot. This script measures both, with an open-loop mix:
#
#   - HEAVY_CLIENTS clients (default 16) run the HEAVY_QUERIES (default the 8
#     slowest: 18 9 13 21 10 5 3 4) back to back for the whole run, each
#     starting the next query the moment its previous one returns. This is the
#     background load; 16 such clients is the regime where run_tpch.sh saw the
#     light queries take ~1 s instead of ~0.1 s.
#   - A light query (LIGHT_QUERIES, default 2 11 6, in turn) arrives every
#     LIGHT_INTERVAL seconds (default 0.5) for DURATION seconds (default 90),
#     whether or not the previous one has finished (open loop). These are the
#     queries whose latency is the result.
#   - Every query passes through a gate before its client is started:
#       none        no gate; everything runs at once (HEAVY_CLIENTS + lights)
#       shared/CAP  at most CAP queries execute at once, light or heavy; a
#                   light query waits for a slot like any other (one queue)
#       bypass/CAP  at most CAP heavy queries execute at once; light queries
#                   skip the gate and start at once (reserved capacity for
#                   short queries, the simplest form of priority)
#       alone       no heavy load at all; the light queries alone, for the
#                   uncontended reference
#     The gate is a counting semaphore (CAP tokens in a pipe), so waiters are
#     admitted in roughly, not strictly, arrival order.
#
# Usage: ./run_mixed.sh   (no arguments; settings come from the environment)
#   CONFIGS         space-separated gate settings to run, each `alone`, `none`,
#                   `shared/CAP` or `bypass/CAP` (CAP 1-9999); default
#                   "alone none shared/8 shared/4 shared/2 bypass/8 bypass/4 bypass/2".
#                   They run in the order given, reversed on even repeats.
#   REPEATS         passes over CONFIGS (default 3).
#   DURATION        seconds light queries keep arriving (default 90). Heavy
#                   queries already running when it ends are left to finish
#                   (the drain), so a run lasts DURATION plus one heavy query.
#   LIGHT_INTERVAL  seconds between light arrivals (default 0.5; up to 3 decimals).
#   LIGHT_QUERIES   light query numbers, used in turn (default "2 11 6").
#   HEAVY_QUERIES   heavy query numbers; client w starts at the w-th and cycles
#                   (default "18 9 13 21 10 5 3 4").
#   HEAVY_CLIENTS   heavy clients (default 16).
#   OUT_DIR         output folder (default ./out_mixed); should be its own folder.
#   WARMUP          1 (default) runs the `none` setting for 20 s unrecorded
#                   first, to warm the page cache and buffer pool; 0 skips it.
#   QUERY_TIMEOUT   seconds after which a query is killed and counted as
#                   failed (default 0 = none).
#   The server's threads setting is left as it is and recorded in system.csv;
#   the sweeps in RESULTS.md say the server should keep all of them.
#
# Output (OUT_DIR):
#   queries.csv  one row per query: config, gate, cap, rep, kind (light/heavy),
#                worker (heavy client number, 0 for light), seq, query, exit,
#                arrival_s (seconds after the run started, when the query was
#                due: a light arrival, or a heavy client finishing its previous
#                query), admitted_s (when it passed the gate and its client
#                started), wait_s (admitted - arrival: time in the queue),
#                seconds (client wall time from admission, including client
#                startup) and query_s (the client's .timer time, which excludes
#                startup and connecting; empty if the query failed). The
#                latency a user would see is wait_s + query_s with a persistent
#                client, or wait_s + seconds with one client process per query.
#   runs.csv     one row per config and repeat: the configured duration, when
#                the last query finished (end_s), how many light and heavy
#                queries ran and how many failed.
#   system.csv   machine, DuckDB version, server threads and the settings.
#   check.csv    per query, whether every successful run returned the same
#                rows (same, reordered, misordered, single, differ, no_results;
#                as in run_tpch.sh; Q11 may be `reordered`, see the README).
#   CONFIG/rN/{l,h}WW_SSSS_qNN.csv  each query's result (l = light, h = heavy,
#                WW the heavy client, SSSS the sequence number), with a .err
#                file next to it when the client wrote to stderr.
#   summarize_mixed.R reads these and writes summary.png / summary.pdf.
#
# Ctrl-C, TERM or HUP stops the test (running clients are killed). Exits 1 if
# any query failed or any result differed or was misordered between runs.
set -u
export LC_ALL=C

(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )) ||
    { echo "bash 5.1 or newer is required" >&2; exit 1; }
for tool in setsid pgrep timeout mkfifo md5sum; do
    command -v "$tool" > /dev/null || { echo "$tool is required" >&2; exit 1; }
done

usage() {
    echo "Usage: $0   (no arguments; set CONFIGS, REPEATS, DURATION, LIGHT_INTERVAL, LIGHT_QUERIES," >&2
    echo "       HEAVY_QUERIES, HEAVY_CLIENTS, OUT_DIR, WARMUP or QUERY_TIMEOUT in the environment; see the header)" >&2
    exit 2
}
bad() { echo "$1 must be $3, not '$2'" >&2; usage; }
is_pos_int() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]]; }
POS_INT="a whole number from 1 to 9999 (no leading zeros)"

[ $# -eq 0 ] || usage

OUT_DIR="${OUT_DIR:-out_mixed}"
case "$OUT_DIR" in -*) OUT_DIR="./$OUT_DIR" ;; esac
while [[ "$OUT_DIR" == */ && -n "${OUT_DIR%/}" ]]; do OUT_DIR=${OUT_DIR%/}; done
WARMUP="${WARMUP:-1}"
[[ "$WARMUP" =~ ^[01]$ ]] || bad WARMUP "$WARMUP" "0 or 1"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-0}"
[[ "$QUERY_TIMEOUT" =~ ^(0|[1-9][0-9]{0,5})$ ]] ||
    bad QUERY_TIMEOUT "$QUERY_TIMEOUT" "a whole number of seconds up to 999999 (0 = no limit, no leading zeros)"
REPEATS="${REPEATS:-3}"
is_pos_int "$REPEATS" || bad REPEATS "$REPEATS" "$POS_INT"
DURATION="${DURATION:-90}"
is_pos_int "$DURATION" || bad DURATION "$DURATION" "$POS_INT"
HEAVY_CLIENTS="${HEAVY_CLIENTS:-16}"
is_pos_int "$HEAVY_CLIENTS" || bad HEAVY_CLIENTS "$HEAVY_CLIENTS" "$POS_INT"
LIGHT_INTERVAL="${LIGHT_INTERVAL:-0.5}"
[[ "$LIGHT_INTERVAL" =~ ^([0-9]{1,4})(\.([0-9]{1,3}))?$ ]] ||
    bad LIGHT_INTERVAL "$LIGHT_INTERVAL" "seconds with up to 3 decimals, like 0.5"
# Whole and fractional parts to microseconds; 10# keeps a leading zero from
# being read as octal.
frac=${BASH_REMATCH[3]}000000
INTERVAL_US=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${frac:0:6} ))
(( INTERVAL_US > 0 )) || bad LIGHT_INTERVAL "$LIGHT_INTERVAL" "more than 0 seconds"
DURATION_US=$(( DURATION * 1000000 ))

# parse_queries VAR NAME: split the query list in $NAME into the array VAR,
# checking each is 1-22.
parse_queries() {
    local -n arr=$1
    read -r -d '' -a arr <<< "${!2}"
    (( ${#arr[@]} > 0 )) || bad "$2" "${!2}" "a space-separated list of query numbers 1-22"
    local q
    for q in "${arr[@]}"; do
        [[ "$q" =~ ^([1-9]|1[0-9]|2[0-2])$ ]] || bad "$2" "${!2}" "a space-separated list of query numbers 1-22"
    done
}
LIGHT_QUERIES="${LIGHT_QUERIES:-2 11 6}"
HEAVY_QUERIES="${HEAVY_QUERIES:-18 9 13 21 10 5 3 4}"
parse_queries LIGHT LIGHT_QUERIES
parse_queries HEAVY HEAVY_QUERIES

CONFIGS="${CONFIGS:-alone none shared/8 shared/4 shared/2 bypass/8 bypass/4 bypass/2}"
read -r -d '' -a configs <<< "$CONFIGS"
(( ${#configs[@]} > 0 )) || bad CONFIGS "$CONFIGS" "at least one setting"
for cfg in "${configs[@]}"; do
    [[ "$cfg" =~ ^(alone|none|(shared|bypass)/[1-9][0-9]{0,3})$ ]] ||
        bad CONFIGS "$cfg" "alone, none, shared/CAP or bypass/CAP (CAP 1-9999)"
    n=0
    for other in "${configs[@]}"; do [ "$other" = "$cfg" ] && n=$((n + 1)); done
    (( n == 1 )) || { echo "CONFIGS lists $cfg more than once" >&2; usage; }
done

# cfg_parts CFG: set gate, cap and dir_name for a setting ("shared/8" gives
# shared, 8 and shared08; alone and none give cap 0 and their own name).
cfg_parts() {
    if [[ "$1" == */* ]]; then
        gate=${1%/*}; cap=${1#*/}
        printf -v dir_name '%s%02d' "$gate" "$cap"
    else
        gate=$1; cap=0; dir_name=$1
    fi
}

duck() { timeout -s KILL 60 duckdb -no-agent -no-init -connect "$@"; }

# Sets Q11_SQL as run_tpch.sh does (threshold scaled to the scale factor).
load_q11() {
    local sql frac
    if ! sql=$(duck -list -noheader -c "SELECT query FROM tpch_queries() WHERE query_nr = 11") ||
        ! frac=$(duck -list -noheader -c "SELECT (0.0001 / (count(*) / 10000))::DECIMAL(24,18) FROM supplier"); then
        echo "Failed to read Q11 or the scale factor from the server" >&2
        die 1
    fi
    [[ "$frac" =~ ^[0-9]+\.[0-9]+$ ]] ||
        { echo "Unexpected Q11 fraction from the server: '$frac'" >&2; die 1; }
    Q11_SQL=${sql/0.0001000000/"$frac"}
    if [ "$Q11_SQL" = "$sql" ]; then
        echo "Warning: Q11's 0.0001 fraction not found; using DuckDB's built-in Q11" >&2
        Q11_SQL="PRAGMA tpch(11)"
    fi
}

# Signal handling as in run_tpch.sh: stop every job, kill its client (a
# setsid session leader, or the `timeout` leading its group) and exit.
# shellcheck disable=SC2329
stop_jobs() {
    local pid kid kids
    for pid in $(jobs -pr); do
        kill -STOP "$pid" 2> /dev/null || continue
        mapfile -t kids < <(pgrep -P "$pid")
        kill -KILL "$pid" 2> /dev/null
        disown "$pid" 2> /dev/null
        for kid in "${kids[@]}"; do
            kill -KILL -- "-$kid" "$kid" 2> /dev/null
        done
    done
    wait
}
# shellcheck disable=SC2329
on_signal() {
    trap '' INT TERM HUP QUIT
    stop_jobs
    CAUGHT=$1
    exit $(( 128 + $(kill -l "$1") ))
}
die() { trap '' INT TERM HUP QUIT; exit "$@"; }
CAUGHT=""
RUN_TMP=""
WARMUP_DIR=""
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap 'on_signal QUIT' QUIT
# shellcheck disable=SC2329
cleanup() {
    local rc=$?
    trap '' INT TERM HUP QUIT PIPE
    stop_jobs
    [ -z "$RUN_TMP" ] || rm -rf -- "$RUN_TMP"
    [ -z "$WARMUP_DIR" ] || rm -rf -- "$WARMUP_DIR"
    if [ -n "$CAUGHT" ]; then
        trap - "$CAUGHT" EXIT
        kill -s "$CAUGHT" $$
    fi
    exit "$rc"
}
trap cleanup EXIT

fmt_us() {
    local us=$2 sign=
    (( us < 0 )) && { sign=-; us=$(( -us )); }
    printf -v "$1" '%s%d.%06d' "$sign" $(( us / 1000000 )) $(( us % 1000000 ))
}
now_us() { printf -v "$1" '%s' "${EPOCHREALTIME/[.,]/}"; }

# run_one KIND WORKER SEQ Q ARRIVAL_US: wait at the gate if KIND is gated in
# this config, run the query in its own client, release the gate and record
# the row. Runs inside a background job; uses the run_config globals RUN_DIR,
# RUN_START, GATE, CAP, LIGHT_GATED, HEAVY_GATED, CFG, REP.
run_one() {
    local kind=$1 worker=$2 seq=$3 q=$4 arrival=$5 gated f err sql s e rc query_s wall arr adm wait_s
    local -a limit=()
    if [ "$kind" = light ]; then gated=$LIGHT_GATED; else gated=$HEAVY_GATED; fi
    printf -v f '%s/%s%02d_%04d_q%02d.csv' "$RUN_DIR" "${kind:0:1}" "$worker" "$seq" "$q"
    err=${f%.csv}.err
    sql="PRAGMA tpch($q)"
    (( q == 11 )) && sql=$Q11_SQL
    (( QUERY_TIMEOUT > 0 )) && limit=(timeout -s KILL "$QUERY_TIMEOUT")
    if (( gated )); then
        # One token per slot; read blocks until one is free (one byte, so
        # concurrent readers can't share a token).
        read -r -n 1 -u 4 _ || { echo "Warning: the gate closed unexpectedly" >&2; }
    fi
    now_us s
    ( trap - TERM HUP; exec setsid -w "${limit[@]}" duckdb -no-agent -no-init -connect -csv -cmd ".timer on" -c "$sql" 3>&- 4>&- ) > "$f" 2> "$err"
    rc=$?
    now_us e
    (( gated )) && printf x >&4
    query_s=$(awk '/^Run Time \(s\): real /{v += $5; n++} END{if (n) printf "%.3f", v}' "$f")
    sed -i '/^Run Time (s): real /d' "$f" ||
        { echo "Warning: could not remove the .timer line from $f; counting it as failed" >&2; rc=1; }
    [ -s "$err" ] || rm -f -- "$err"
    (( rc == 0 )) || query_s=
    fmt_us wall $(( e - s ))
    fmt_us arr $(( arrival - RUN_START ))
    fmt_us adm $(( s - RUN_START ))
    fmt_us wait_s $(( s - arrival ))
    if [ -n "$QUERIES_CSV" ] && ! printf '%s,%s,%d,%d,%s,%d,%d,%d,%d,%s,%s,%s,%s,%s\n' "$CFG" "$GATE" "$CAP" "$REP" \
        "$kind" "$worker" "$seq" "$q" "$rc" "$arr" "$adm" "$wait_s" "$wall" "$query_s" >> "$QUERIES_CSV"; then
        echo "Warning: could not record a query in $QUERIES_CSV; counting it as failed" >&2
        rc=1
    fi
    (( rc == 0 )) || printf 'Q%02d (%s) failed, exit=%d, see %s\n' "$q" "$kind" "$rc" "$err"
    return $rc
}

# heavy_worker W: run the heavy queries back to back until the stop flag appears.
heavy_worker() {
    local w=$1 i=0 idx=$1 q arrival
    while [ ! -e "$STOP_FLAG" ]; do
        q=${HEAVY[idx % ${#HEAVY[@]}]}
        idx=$((idx + 1)); i=$((i + 1))
        now_us arrival
        run_one heavy "$w" "$i" "$q" "$arrival"
    done
}

# run_config CFG REP DIR DURATION_US: one run of a setting.
run_config() {
    CFG=$1; REP=$2; RUN_DIR=$3
    local dur_us=$4 w i target now sl end light_n heavy_n failed
    cfg_parts "$CFG"
    GATE=$gate; CAP=$cap
    LIGHT_GATED=0; HEAVY_GATED=0
    [ "$GATE" = shared ] && LIGHT_GATED=1
    [[ "$GATE" == shared || "$GATE" == bypass ]] && HEAVY_GATED=1
    mkdir -p -- "$RUN_DIR" || { echo "Failed to create $RUN_DIR" >&2; die 1; }
    RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/run_mixed.XXXXXX") || { echo "Failed to create a temporary folder" >&2; die 1; }
    STOP_FLAG="$RUN_TMP/stop"
    if (( HEAVY_GATED )); then
        mkfifo -m 600 "$RUN_TMP/gate" || { echo "Failed to create the gate" >&2; die 1; }
        exec 4<> "$RUN_TMP/gate"
        for (( i = 0; i < CAP; i++ )); do printf x; done >&4
    fi
    now_us RUN_START
    if [ "$GATE" != alone ]; then
        for (( w = 1; w <= HEAVY_CLIENTS; w++ )); do
            { trap '' TERM HUP; heavy_worker "$w"; } &
        done
    fi
    i=0
    while :; do
        target=$(( RUN_START + i * INTERVAL_US ))
        (( target < RUN_START + dur_us )) || break
        now_us now
        if (( target > now )); then
            fmt_us sl $(( target - now ))
            sleep "$sl"
        fi
        now_us now
        { trap '' TERM HUP; run_one light 0 $((i + 1)) "${LIGHT[i % ${#LIGHT[@]}]}" "$now"; } &
        i=$((i + 1))
    done
    : > "$STOP_FLAG"
    wait
    now_us now
    fmt_us end $(( now - RUN_START ))
    (( HEAVY_GATED )) && exec 4>&-
    rm -rf -- "$RUN_TMP"; RUN_TMP=""
    light_n=$i; heavy_n=0; failed=0
    if [ -n "$QUERIES_CSV" ]; then
        read -r light_n heavy_n failed < <(awk -F, -v c="$CFG" -v r="$REP" \
            '$1 == c && $4 == r {if ($5 == "light") l++; else h++; if ($9 != 0) f++} END {print l + 0, h + 0, f + 0}' "$QUERIES_CSV")
        printf '%s,%s,%d,%d,%d,%s,%d,%d,%d\n' "$CFG" "$GATE" "$CAP" "$REP" "$(( dur_us / 1000000 ))" "$end" \
            "$light_n" "$heavy_n" "$failed" >> "$RUNS_CSV" || { echo "Failed to write to $RUNS_CSV" >&2; die 1; }
    fi
    printf '%s repeat %d: %d light and %d heavy queries, last finished at %ss (%d failed). Results in %s/\n' \
        "$CFG" "$REP" "$light_n" "$heavy_n" "$end" "$failed" "$RUN_DIR"
    FAILED=$failed
}

csv_row() { printf '%s,"%s"\n' "$1" "${2//\"/\"\"}"; }
write_system_info() {
    local cpu sockets cores_per_socket cores='' mem version lscpu_out
    lscpu_out=$(lscpu 2> /dev/null)
    cpu=$(sed -n 's/^[[:space:]]*Model name:[[:space:]]*//p' <<< "$lscpu_out" | awk '!seen[$0]++' | paste -sd '\t' -)
    cpu=${cpu//$'\t'/ + }
    sockets=$(sed -n 's/^[[:space:]]*Socket(s):[[:space:]]*//p' <<< "$lscpu_out" | head -1)
    cores_per_socket=$(sed -n 's/^[[:space:]]*Core(s) per socket:[[:space:]]*//p' <<< "$lscpu_out" | head -1)
    [[ "$sockets" =~ ^[1-9][0-9]*$ && "$cores_per_socket" =~ ^[1-9][0-9]*$ ]] && cores=$(( sockets * cores_per_socket ))
    mem=$(awk '/^MemTotal:/ {printf "%.1f", $2 / 1048576}' /proc/meminfo 2> /dev/null)
    version=$(duck -list -noheader -c "SELECT version()" 2> /dev/null)
    {
        echo "key,value"
        csv_row cpu "$cpu"
        csv_row cores "$cores"
        csv_row logical_cpus "$(getconf _NPROCESSORS_ONLN 2> /dev/null)"
        csv_row memory_gib "$mem"
        csv_row duckdb "$version"
        csv_row threads "$server_threads"
        csv_row configs "$CONFIGS"
        csv_row duration_s "$DURATION"
        csv_row light_interval_s "$LIGHT_INTERVAL"
        csv_row light_queries "$LIGHT_QUERIES"
        csv_row heavy_queries "$HEAVY_QUERIES"
        csv_row heavy_clients "$HEAVY_CLIENTS"
        csv_row repeats "$REPEATS"
        csv_row query_timeout "$QUERY_TIMEOUT"
    } > "$1"
}

# check_results: as in run_tpch.sh, over every result file with an exit 0 row.
check_results() {
    local q f files status differ=() reordered=() misordered=() single=() never_ok=()
    local -A ok=()
    while read -r f; do
        ok[$f]=1
    # The folder is the setting's dir_name (shared08 for shared/8), not the
    # setting itself.
    done < <(awk -F, 'NR > 1 && $9 == 0 {dir = ($3 == 0) ? $2 : sprintf("%s%02d", $2, $3);
        printf "%s/r%d/%s%02d_%04d_q%02d.csv\n", dir, $4, substr($5, 1, 1), $6, $7, $8}' "$QUERIES_CSV")
    echo "query,status" > "$OUT_DIR/check.csv"
    for q in $(printf '%s\n' "${LIGHT[@]}" "${HEAVY[@]}" | sort -n -u); do
        files=()
        for f in "$OUT_DIR"/*/r*/[lh][0-9][0-9]_[0-9][0-9][0-9][0-9]_"q$(printf '%02d' "$q").csv"; do
            [ -f "$f" ] && [ -n "${ok[${f#"$OUT_DIR"/}]:-}" ] && files+=("$f")
        done
        if (( ${#files[@]} == 0 )); then
            status=no_results; never_ok+=("Q$q")
        elif (( ${#files[@]} == 1 )); then
            status=single; single+=("Q$q")
        elif (( $(md5sum -- "${files[@]}" | awk '{print $1}' | sort -u | wc -l) == 1 )); then
            status=same
        elif (( $(for f in "${files[@]}"; do sort -- "$f" | md5sum; done | sort -u | wc -l) == 1 )); then
            if (( q == 11 )); then status=reordered; reordered+=("Q$q"); else status=misordered; misordered+=("Q$q"); fi
        else
            status=differ; differ+=("Q$q")
        fi
        echo "$q,$status" >> "$OUT_DIR/check.csv"
    done
    (( ${#never_ok[@]} == 0 )) || echo "Warning: ${never_ok[*]} succeeded in no run, so there are no results to compare" >&2
    (( ${#single[@]} == 0 )) || echo "Warning: ${single[*]} succeeded in only one run, so there was nothing to compare" >&2
    (( ${#reordered[@]} == 0 )) ||
        echo "Note: ${reordered[*]} returned the same rows in every successful run, but rows with tied ORDER BY values came back in different orders"
    (( ${#misordered[@]} == 0 )) ||
        echo "Warning: ${misordered[*]} returned the same rows in different orders, although the ORDER BY has no ties" >&2
    (( ${#differ[@]} == 0 )) || echo "Warning: results differ between runs for ${differ[*]}" >&2
    (( ${#never_ok[@]} + ${#single[@]} + ${#misordered[@]} + ${#differ[@]} == 0 )) &&
        echo "Every query returned the same rows in every successful run"
    (( ${#misordered[@]} + ${#differ[@]} == 0 ))
}

server_threads=$(duck -list -noheader -c "SELECT current_setting('threads')") ||
    { echo "Failed to reach the server (is ./start_server.sh running?)" >&2; die 1; }
echo "Server threads = $server_threads (left unchanged)"
load_q11

mkdir -p -- "$OUT_DIR" || { echo "Failed to create $OUT_DIR" >&2; die 1; }
write_test=$(mktemp -- "$OUT_DIR/.write_test.XXXXXX") || { echo "Cannot write to $OUT_DIR" >&2; die 1; }
rm -f -- "$write_test"

QUERIES_CSV=""
RUNS_CSV=""
if [ "$WARMUP" = 1 ]; then
    echo "Warm-up: 20 s of the none setting (not recorded; WARMUP=0 to skip)"
    WARMUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/run_mixed_warmup.XXXXXX") || { echo "Failed to create a temporary folder" >&2; die 1; }
    run_config none 0 "$WARMUP_DIR/none/r0" $(( 20 * 1000000 )) > /dev/null
    rm -rf -- "$WARMUP_DIR"; WARMUP_DIR=""
fi

rm -rf -- "$OUT_DIR"/{alone,none,shared[0-9][0-9]*,bypass[0-9][0-9]*} "$OUT_DIR/check.csv" "$OUT_DIR/summary.png" "$OUT_DIR/summary.pdf"
RUNS_CSV="$OUT_DIR/runs.csv"
QUERIES_CSV="$OUT_DIR/queries.csv"
{ write_system_info "$OUT_DIR/system.csv" &&
    echo "config,gate,cap,rep,duration_s,end_s,light_n,heavy_n,failed" > "$RUNS_CSV" &&
    echo "config,gate,cap,rep,kind,worker,seq,query,exit,arrival_s,admitted_s,wait_s,seconds,query_s" > "$QUERIES_CSV"; } ||
    { echo "Failed to write to $OUT_DIR" >&2; die 1; }

echo "Running $CONFIGS (${#configs[@]} settings x $REPEATS repeats, $DURATION s each, light query every $LIGHT_INTERVAL s, $HEAVY_CLIENTS heavy clients)"
total_failed=0
for rep in $(seq 1 "$REPEATS"); do
    for (( i = 0; i < ${#configs[@]}; i++ )); do
        if (( rep % 2 )); then cfg=${configs[i]}; else cfg=${configs[${#configs[@]} - 1 - i]}; fi
        cfg_parts "$cfg"
        echo "=== $cfg repeat $rep/$REPEATS ==="
        run_config "$cfg" "$rep" "$OUT_DIR/$dir_name/r$rep" "$DURATION_US"
        total_failed=$((total_failed + FAILED))
    done
done
echo "Done ($total_failed failed queries). Timings in $RUNS_CSV and $QUERIES_CSV"
check_results
check_rc=$?
die $(( total_failed > 0 || check_rc != 0 ))
