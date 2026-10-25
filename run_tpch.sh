#!/usr/bin/env bash
# Run TPC-H queries 1-22 against a running DuckDB quack server
# (started with: ./start_server.sh), sweeping N (queries in flight at once)
# against THREADS (the server's `SET threads`). Each query gets its own
# `duckdb -connect` client. The clients connect to the default quack server
# (localhost:9494) with the stored default quack secret, so run this on the
# server's machine as the user (and HOME) that started the server; remote
# servers aren't supported.
#
# Usage: ./run_tpch.sh   (no arguments; settings come from the environment)
#   Run every combination of N = 1..min(22, CPUs) and THREADS = 1..CPUs
#   where N + THREADS - 1 (roughly the threads a run uses; see the note below)
#   is within MARGIN (default 0) of CPUs. If even N = 22 can't reach that for
#   a given THREADS (N is capped at 22 since there are only 22 queries), N = 22
#   is used for that THREADS instead.
#   Any other THREADS with no N in range is skipped, with a warning; that
#   includes THREADS that only a MAX_JOBS below 22 keeps out of range.
#   CPUs defaults to `nproc`; override with CPUS, MAX_JOBS / MAX_THREADS, MARGIN
#   (each at most 9999). Raising MARGIN (or MAX_JOBS, when it is below 22)
#   brings skipped THREADS values into range.
#   Or set COMBOS to the exact combinations to run, as space-separated NxT
#   pairs (e.g. COMBOS="1x24 2x24 4x24 8x24 16x24 22x24" holds THREADS at 24
#   and varies N; COMBOS="4x1 4x2 4x4 4x8 4x16 4x24" holds N at 4). N is 1..22
#   and THREADS 1..9999, no pair twice; they run in the order given. With
#   COMBOS set, CPUS, MARGIN, MAX_JOBS and MAX_THREADS are ignored (with a
#   warning if any of them is set), and the CPU budget is not kept: e.g. 22x24
#   runs ~45 threads on a 24-CPU machine.
#   Every combination runs REPEATS times (default 3), one full pass over all
#   combinations per repeat, in reverse order on even repeats so that drift
#   over the sweep (cache state, heat, turbo) doesn't line up with THREADS.
#   Output goes to OUT_DIR/jNN_tNN/rN/qNN.csv (OUT_DIR defaults to ./out,
#   relative to the current directory, and should be a folder of its own;
#   tNNN or tNNNN for THREADS >= 100; old jNN_tNN folders, check.csv and
#   summarize_tpch.R's summary.png and summary.pdf are removed from it after
#   the warm-up), with timings in OUT_DIR/runs.csv (one row per combination
#   and repeat) and OUT_DIR/queries.csv (one row per query). The machine's CPU,
#   memory, the server's DuckDB version and the sweep's settings go to
#   OUT_DIR/system.csv. At the end, each
#   query's results are compared across all runs, with the outcome per query in
#   OUT_DIR/check.csv (same, reordered, misordered, single, differ or
#   no_results; see check_results).
#   The server's original threads setting is restored at the end (giving up
#   after 30 seconds). The other statements run outside the queries (reading
#   and setting threads, loading Q11) give up after 60 seconds, which fails
#   the sweep, so a server that stops answering can't hang it; the DuckDB
#   version lookup for system.csv gives up too, but only leaves the version
#   empty. The queries themselves have no time limit unless QUERY_TIMEOUT is
#   set (seconds, default 0 = none): a query still running after that is
#   killed and counts as failed.
#   Ctrl-C, TERM or HUP stops the sweep (the running clients are killed and
#   threads restored). A sweep started with `&` from a script ignores INT and
#   QUIT (bash does so for background children of a non-interactive shell),
#   so stop one of those with TERM.
#   Exits 1 if any query failed (or its queries.csv row couldn't be written),
#   any query's results differ between runs or are misordered (same rows,
#   different order with no ORDER BY ties), or the threads setting couldn't
#   be restored. A runs.csv row that can't be written (disk full) stops the
#   sweep with exit 1.
#
# Note that THREADS is neither a per-query thread count nor a cap on the whole
# server: `SET threads` is a server-wide setting that starts THREADS - 1 shared
# background workers, and the thread serving each in-flight query also works
# on it. So a run uses roughly N + THREADS - 1 threads, not N * THREADS (e.g.
# 22 x 1 runs ~22 threads, 6 x 4 ~9, 1 x 24 ~24), which is why combinations
# are picked by N + THREADS - 1: that keeps the CPU budget roughly constant.
#
# Before the sweep, all 22 queries run once unrecorded (with the server's
# original threads setting and the largest N) to warm the page cache and
# DuckDB's buffer pool; set WARMUP=0 to skip that.
#
# Every run:
#   Queries start in QUERY_ORDER (default: longest first, by uncontended runtime
#   on SF100), so the long ones don't end up as a tail with few queries running.
#   Q11 has its threshold fraction scaled to the database's scale factor (the
#   built-in one is only right at SF1).
#   queries.csv records each query's start (seconds after the run started, to
#   the microsecond so start order is unambiguous),
#   its wall time including client startup (seconds), and the time the
#   client's .timer reports for the query (query_s; empty if the query failed
#   or the client printed no .timer line).
#   query_s excludes client startup and connecting, but is measured on the
#   client, so it includes the round trip, result transfer and CSV output.
#   runs.csv's seconds is the wall time for all 22 queries, so it includes
#   each client's startup and connecting, which overlap less at small N
#   (summarize_tpch.R ranks configurations on the run replayed with each
#   query's query_s instead; see its header).
#   A client's stderr (errors, warnings) goes to qNN.err next to qNN.csv,
#   which is removed when empty.
set -u
# EPOCHREALTIME must use '.' as the decimal point, and the sort in
# check_results and the regexes here must not depend on the locale.
export LC_ALL=C

(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )) ||
    { echo "bash 5.1 or newer is required (for wait -n -p; EPOCHREALTIME needs 5.0)" >&2; exit 1; }
command -v setsid > /dev/null || { echo "setsid (util-linux) is required" >&2; exit 1; }
command -v pgrep > /dev/null || { echo "pgrep (procps) is required" >&2; exit 1; }
command -v timeout > /dev/null || { echo "timeout (coreutils) is required" >&2; exit 1; }

usage() {
    echo "Usage: $0   (no arguments; set CPUS, MAX_JOBS, MAX_THREADS, MARGIN or COMBOS, and REPEATS," >&2
    echo "       OUT_DIR, WARMUP, QUERY_ORDER or QUERY_TIMEOUT in the environment; see the header)" >&2
    exit 2
}

# bad NAME VALUE WHAT: report an invalid setting and exit.
bad() { echo "$1 must be $3, not '$2'" >&2; usage; }

# At most 4 digits, which keeps the sums below far from overflowing and the
# folder names within the tNN/tNNN/tNNNN patterns. No leading zeros, which
# bash arithmetic would read as octal.
is_pos_int() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]]; }
POS_INT="a whole number from 1 to 9999 (no leading zeros)"

[ $# -eq 0 ] || usage

OUT_DIR="${OUT_DIR:-out}"
# Keep a folder name starting with '-' from being read as an option, and drop
# trailing '/'s (but not a lone '/') so paths don't print as out//jNN_tNN.
case "$OUT_DIR" in -*) OUT_DIR="./$OUT_DIR" ;; esac
while [[ "$OUT_DIR" == */ && -n "${OUT_DIR%/}" ]]; do OUT_DIR=${OUT_DIR%/}; done
WARMUP="${WARMUP:-1}"
QUERY_ORDER="${QUERY_ORDER:-18 9 13 21 10 5 3 4 1 7 14 16 20 8 17 12 22 19 15 6 2 11}"
RUNS_CSV=""
QUERIES_CSV=""

[[ "$WARMUP" =~ ^[01]$ ]] || bad WARMUP "$WARMUP" "0 or 1"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-0}"
[[ "$QUERY_TIMEOUT" =~ ^(0|[1-9][0-9]{0,5})$ ]] ||
    bad QUERY_TIMEOUT "$QUERY_TIMEOUT" "a whole number of seconds up to 999999 (0 = no limit, no leading zeros)"
# Split on IFS only (space, tab, newline), so that e.g. a CR or vertical tab
# can't pass here and then end up inside a query number.
read -r -d '' -a QUERIES <<< "$QUERY_ORDER"
(( ${#QUERIES[@]} == 22 )) &&
    [ "$(printf '%s\n' "${QUERIES[@]}" | grep -xE '[1-9]|1[0-9]|2[0-2]' | sort -u | wc -l)" = 22 ] ||
    { echo "QUERY_ORDER must list each of the queries 1-22 once" >&2; exit 2; }

# -no-init: a ~/.duckdbrc could add .timer lines (which run_query would count
# into query_s), change the CSV separator or headers (-csv only sets the
# mode), or the server connected to.
# The timeout keeps a server that stops answering from hanging the script in
# a foreground client, where bash can't run the signal traps until it exits.
# KILL, since the client is in the script's process group and may be stuck in
# a socket read; the exit status is then 137 with GNU timeout and 124 with
# uutils coreutils (only non-zero matters here).
duck() { timeout -s KILL 60 duckdb -no-agent -no-init -connect "$@"; }

set_threads() {
    duck -c "SET threads = $1" > /dev/null || {
        echo "Failed to set threads = $1 on the server" >&2
        die 1
    }
}

get_threads() {
    duck -list -noheader -c "SELECT current_setting('threads')" || {
        echo "Failed to read threads from the server" >&2
        die 1
    }
}

# Sets Q11_SQL: DuckDB's Q11 with its hard-coded 0.0001 (correct at SF1 only)
# replaced by 0.0001 / SF, as the TPC-H spec requires. SF = suppliers / 10000.
load_q11() {
    local sql frac
    if ! sql=$(duck -list -noheader -c "SELECT query FROM tpch_queries() WHERE query_nr = 11") ||
        ! frac=$(duck -list -noheader -c "SELECT (0.0001 / (count(*) / 10000))::DECIMAL(24,18) FROM supplier"); then
        echo "Failed to read Q11 or the scale factor from the server" >&2
        die 1
    fi
    [[ "$frac" =~ ^[0-9]+\.[0-9]+$ ]] ||
        { echo "Unexpected Q11 fraction from the server: '$frac'" >&2; die 1; }
    # The replacement is quoted so that bash 5.2's patsub_replacement can't
    # expand an '&' in it (none today, but a quoted replacement is literal).
    Q11_SQL=${sql/0.0001000000/"$frac"}
    if [ "$Q11_SQL" = "$sql" ]; then
        echo "Warning: Q11's 0.0001 fraction not found; using DuckDB's built-in Q11" >&2
        Q11_SQL="PRAGMA tpch(11)"
    fi
}

# Background jobs ignore SIGINT, but duckdb installs its own handler, so the
# clients run in their own session (setsid) where the terminal's Ctrl-C can't
# reach them. The run_query subshells also ignore TERM and HUP, so a signal to
# the whole process group (closing the terminal, kill -TERM -PGID) can't kill
# them and leave their clients running unseen. On Ctrl-C/TERM/HUP/QUIT (and
# from cleanup, for any other exit with a run in flight) stop each run_query
# subshell (so it can't start a client between pgrep and kill), find its
# children, kill it (before its client, so it can't record the client's death
# as a failed query) and then them, and exit, which runs cleanup.
# The children get KILL, not TERM: a child that is the client's subshell,
# forked but not yet past its `trap - TERM HUP`, still ignores TERM (inherited
# from the job) and would go on to start the client. Each child is killed
# together with the process group it leads: the client is a session and group
# leader (setsid), and with QUERY_TIMEOUT the child is `timeout`, which leads
# the group its duckdb is in. A child that hasn't exec'd setsid yet leads no
# group (it is in the script's), so only the plain kill reaches it. Each
# killed job is disowned so that bash doesn't print a "Killed" line per job.
# Only running jobs (-r): a finished job has no live client, and its pid may
# already belong to another process.
# shellcheck disable=SC2329  # invoked from the traps below
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
# on_signal SIG: stop the jobs and exit; cleanup then re-raises SIG so that a
# calling script sees the script killed by it (e.g. a bash loop stops on Ctrl-C).
# Except for QUIT: bash always ignores SIGQUIT, so the re-raise does nothing
# and the script exits 131 instead.
# Further signals are ignored first: bash runs a trap handler again when its
# signal arrives while it is running, so a second Ctrl-C could restart
# stop_jobs part-way (leaving a client unseen) or, between the exit below and
# cleanup's own `trap ''`, exit again without cleanup restoring threads.
# shellcheck disable=SC2329  # invoked from the traps below
on_signal() {
    trap '' INT TERM HUP QUIT
    stop_jobs
    CAUGHT=$1
    exit $(( 128 + $(kill -l "$1") ))
}
# die [STATUS]: exit from the main flow (and from the functions it calls once
# the traps below are set) with the signals ignored first. bash runs a pending
# trap before the EXIT trap's first command and again after its `local rc=$?`,
# i.e. before cleanup's own `trap ''`, so a signal arriving as cleanup starts
# would run on_signal there, whose exit skips the rest of cleanup (the threads
# restore) and replaces the exit status with 128 + signal. A signal that
# arrives before the `trap ''` here is handled as usual: on_signal, then exit
# into cleanup with the signals already ignored.
die() { trap '' INT TERM HUP QUIT; exit "$@"; }
CAUGHT=""
WARMUP_DIR=""
original_threads=""
# The script's stdout for cleanup, which may run inside the warm-up's
# > /dev/null.
exec 3>&1
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap 'on_signal QUIT' QUIT

# EXIT trap: remove the warm-up folder and, once the server's original threads
# setting is known, put it back. Keeps the script's exit status, except that a
# run that succeeded exits 1 if the restore fails or times out.
# shellcheck disable=SC2329  # invoked from the EXIT trap below
cleanup() {
    local rc=$?
    # A second Ctrl-C must not cut the restore short, in this shell or in the
    # client (hence setsid, as duckdb catches SIGINT itself). Signals can't
    # stop it, so a timeout keeps a hung server from hanging the script. PIPE
    # too, so the messages below can't kill this shell before `exit "$rc"`.
    # (on_signal and die have already ignored the signals before exiting, so
    # none can run a trap between entering cleanup and this line; only a
    # `set -u` abort still gets here with them trapped.)
    # The timeout sends KILL: the ignored TERM is inherited through exec, so
    # timeout's default TERM would do nothing and only its -k would end the
    # client, 5 seconds after the 30 the header promises.
    trap '' INT TERM HUP QUIT PIPE
    # Jobs still running (this shell died of an untrapped signal, e.g. SIGPIPE
    # from a closed `| head`, or exited with a run in flight) are stopped
    # first, so the restore below doesn't change threads under a running run.
    stop_jobs
    [ -z "$WARMUP_DIR" ] || rm -rf -- "$WARMUP_DIR"
    if [ -n "$original_threads" ]; then
        # 3>&-: see run_query.
        if setsid -w timeout -s KILL 30 duckdb -no-agent -no-init -connect -c "SET threads = $original_threads" > /dev/null 3>&-; then
            echo "Restored threads = $original_threads" >&3 2> /dev/null
        else
            echo "Warning: failed to restore threads = $original_threads on the server" >&2
            (( rc == 0 )) && rc=1
        fi
    fi
    if [ -n "$CAUGHT" ]; then
        trap - "$CAUGHT" EXIT
        kill -s "$CAUGHT" $$
    fi
    exit "$rc"
}
trap cleanup EXIT

# fmt_us VAR MICROSECONDS [DECIMALS]: set VAR to the time in seconds with 3
# (or 6) decimals, negative if the wall clock stepped back. It sets a variable
# instead of printing to save a fork per call.
fmt_us() {
    local us=$2 sign=
    (( us < 0 )) && { sign=-; us=$(( -us )); }
    if [ "${3:-3}" = 6 ]; then
        printf -v "$1" '%s%d.%06d' "$sign" $(( us / 1000000 )) $(( us % 1000000 ))
    else
        printf -v "$1" '%s%d.%03d' "$sign" $(( us / 1000000 )) $(( us % 1000000 / 1000 ))
    fi
}

# run_query DIR JOBS THREADS REP Q RUN_START_US
run_query() {
    local dir=$1 jobs=$2 threads=$3 rep=$4 q=$5 run_start=$6 f err sql s e rc query_s wall start
    local -a limit=()
    printf -v f '%s/q%02d.csv' "$dir" "$q"
    err=${f%.csv}.err
    sql="PRAGMA tpch($q)"
    (( q == 11 )) && sql=$Q11_SQL
    # With QUERY_TIMEOUT, timeout sits between setsid and duckdb and leads the
    # process group duckdb runs in (see stop_jobs). It sends KILL, as the
    # client may be stuck in a socket read; the status is then 124 or 137.
    (( QUERY_TIMEOUT > 0 )) && limit=(timeout -s KILL "$QUERY_TIMEOUT")
    s=${EPOCHREALTIME/[.,]/}
    # The client gets TERM and HUP back (this subshell ignores them), so a
    # plain kill can end it. fd 3 (the script's stdout, kept for cleanup) is
    # closed, so a client that outlives the script can't hold the script's
    # stdout pipe open. setsid doesn't fork here (this subshell isn't a process
    # group leader); -w keeps the exit status right if it ever did.
    ( trap - TERM HUP; exec setsid -w "${limit[@]}" duckdb -no-agent -no-init -connect -csv -cmd ".timer on" -c "$sql" 3>&- ) > "$f" 2> "$err"
    rc=$?
    e=${EPOCHREALTIME/[.,]/}
    # Move .timer's "Run Time (s): real X user Y sys Z" line out of the
    # results (one line per -c even for several statements in DuckDB 2.0;
    # summed in case that changes). If that fails (disk full), the line
    # would stay in the results and make them differ, so count the query as
    # failed instead.
    query_s=$(awk '/^Run Time \(s\): real /{v += $5; n++} END{if (n) printf "%.3f", v}' "$f")
    sed -i '/^Run Time (s): real /d' "$f" ||
        { echo "Warning: could not remove the .timer line from $f; counting Q$q as failed" >&2; rc=1; }
    [ -s "$err" ] || rm -f -- "$err"
    # .timer reports a time for failed queries too; don't record it as a query time.
    (( rc == 0 )) || query_s=
    fmt_us wall $(( e - s ))
    fmt_us start $(( s - run_start )) 6
    # The CSV row first: check_results only trusts results that have one with
    # exit 0, so this shell dying at the terminal output (e.g. SIGPIPE from a
    # closed `| tee`) can't leave a result that passes for a successful one.
    # (reap_one then counts this job as failed although its row says exit 0;
    # the script itself dies of the same SIGPIPE at its next echo.)
    # A row that can't be written (disk full) would leave the run looking
    # unfinished to summarize_tpch.R, so count the query as failed.
    if [ -n "$QUERIES_CSV" ] && ! printf '%d,%s,%d,%d,%d,%s,%s,%s\n' "$jobs" "$threads" "$rep" "$q" "$rc" \
        "$start" "$wall" "$query_s" >> "$QUERIES_CSV"; then
        echo "Warning: could not record Q$q in $QUERIES_CSV; counting it as failed" >&2
        rc=1
    fi
    printf 'Q%02d  exit=%d  %8ss  (query %ss)\n' "$q" "$rc" "$wall" "${query_s:-?}"
    return $rc
}

# reap_one: wait for one of the jobs in PIDS (run_benchmark's), drop it from
# PIDS and count it in FAILED if it failed.
# A job that dies of a signal (an OOM kill, SIGPIPE at its printf) while this
# shell is between two waits is reported by bash at the next command boundary.
# bash 5.3's `wait -n` still returns its status, but 5.1 and 5.2 skip it
# (printing "no such job", hence the 2> /dev/null) and wait for the other
# jobs, so the pool would run a slot short for the rest of the run and the
# status would surface as a 127 only at the end. So jobs that are already
# dead are reaped first, one per call: bash has reaped every dead child, so
# `kill -0` fails for exactly those, and a plain `wait PID` then returns the
# saved status at once on every version (0, the exit status or 128 + signal;
# verified on 5.1, 5.2 and 5.3). Only then does `wait -n` block for a live
# one. (A dead job's pid reused by a new process in the meantime would keep
# its slot until the run's final waits return 127.)
reap_one() {
    local pid rc i
    for i in "${!PIDS[@]}"; do
        kill -0 "${PIDS[i]}" 2> /dev/null && continue
        wait "${PIDS[i]}" 2> /dev/null
        rc=$?
        (( rc == 0 )) || FAILED=$((FAILED + 1))
        unset 'PIDS[i]'
        return
    done
    # `wait -n -p` unsets pid before waiting and leaves it unset when it
    # returns no job, hence ${pid:-} below (set -u).
    wait -n -p pid "${PIDS[@]}" 2> /dev/null
    rc=$?
    if [ -z "${pid:-}" ]; then
        # 127: none of PIDS is a child any more; nothing left to reap.
        echo "Warning: lost the exit status of ${#PIDS[@]} queries; counting them as failed" >&2
        FAILED=$((FAILED + ${#PIDS[@]}))
        PIDS=()
        return
    fi
    (( rc == 0 )) || FAILED=$((FAILED + 1))
    for i in "${!PIDS[@]}"; do
        [ "${PIDS[i]}" = "$pid" ] && unset 'PIDS[i]'
    done
}

# run_benchmark DIR JOBS THREADS REP -> sets FAILED
run_benchmark() {
    local dir=$1 jobs=$2 threads=$3 rep=$4 start_all secs q
    FAILED=0
    PIDS=()
    mkdir -p -- "$dir" || { echo "Failed to create $dir" >&2; die 1; }
    start_all=${EPOCHREALTIME/[.,]/}

    for q in "${QUERIES[@]}"; do
        (( ${#PIDS[@]} < jobs )) || reap_one
        # TERM and HUP ignored: see stop_jobs.
        { trap '' TERM HUP; run_query "$dir" "$jobs" "$threads" "$rep" "$q" "$start_all"; } &
        PIDS+=("$!")
    done

    while (( ${#PIDS[@]} > 0 )); do
        reap_one
    done

    fmt_us secs $(( ${EPOCHREALTIME/[.,]/} - start_all ))
    printf 'All 22 queries finished in %ss with parallelism %d, threads %s (%d failed). Results in %s/\n' \
        "$secs" "$jobs" "$threads" "$FAILED" "$dir"
    # Without its runs.csv row the run is lost (summarize_tpch.R treats it as
    # unfinished), and the next runs would be too: stop the sweep.
    if [ -n "$RUNS_CSV" ] && ! printf '%d,%s,%d,%s,%d\n' "$jobs" "$threads" "$rep" "$secs" "$FAILED" >> "$RUNS_CSV"; then
        echo "Failed to write to $RUNS_CSV" >&2
        die 1
    fi
}

# warm_up JOBS THREADS: unrecorded pass so the first timed run doesn't pay for
# a cold page cache. Its results go to a temporary folder outside OUT_DIR, so
# nothing in OUT_DIR is touched (cleanup removes it if interrupted).
warm_up() {
    [ "$WARMUP" = 1 ] || return 0
    echo "Warm-up: running all 22 queries once (not recorded; WARMUP=0 to skip)"
    WARMUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/run_tpch_warmup.XXXXXX") ||
        { echo "Failed to create a temporary folder for the warm-up" >&2; die 1; }
    run_benchmark "$WARMUP_DIR" "$1" "$2" 0 > /dev/null
    rm -rf -- "$WARMUP_DIR"
    WARMUP_DIR=""
    (( FAILED == 0 )) || echo "Warning: $FAILED queries failed during warm-up" >&2
}

# write_system_info FILE: CPU, memory and DuckDB version as key,value CSV.
# The hardware is this machine's, which is also the server's when it was
# started locally with ./start_server.sh. Unknown values are left empty.
write_system_info() {
    local cpu sockets cores_per_socket cores='' mem version lscpu_out
    # lscpu from util-linux 2.37-2.39 (Ubuntu 22.04, Debian 12) indents these
    # fields under their parents, hence the leading blanks in the patterns.
    lscpu_out=$(lscpu 2> /dev/null)
    # Heterogeneous (big.LITTLE) ARM machines print one Model name per core
    # type; keep them all, joined with " + ".
    cpu=$(sed -n 's/^[[:space:]]*Model name:[[:space:]]*//p' <<< "$lscpu_out" | awk '!seen[$0]++' | paste -sd '\t' -)
    cpu=${cpu//$'\t'/ + }
    sockets=$(sed -n 's/^[[:space:]]*Socket(s):[[:space:]]*//p' <<< "$lscpu_out" | head -1)
    cores_per_socket=$(sed -n 's/^[[:space:]]*Core(s) per socket:[[:space:]]*//p' <<< "$lscpu_out" | head -1)
    # lscpu prints "Socket(s): -" on some ARM systems.
    [[ "$sockets" =~ ^[1-9][0-9]*$ && "$cores_per_socket" =~ ^[1-9][0-9]*$ ]] &&
        cores=$(( sockets * cores_per_socket ))
    mem=$(awk '/^MemTotal:/ {printf "%.1f", $2 / 1048576}' /proc/meminfo 2> /dev/null)
    version=$(duck -list -noheader -c "SELECT version()" 2> /dev/null)
    {
        echo "key,value"
        csv_row cpu "$cpu"
        csv_row cores "$cores"
        # All online CPUs, unlike nproc, which honours OMP_NUM_THREADS and affinity.
        csv_row logical_cpus "$(getconf _NPROCESSORS_ONLN 2> /dev/null)"
        csv_row memory_gib "$mem"
        csv_row duckdb "$version"
        # The sweep's settings, so the output says what budget it covered
        # (or, with COMBOS, which combinations were asked for; the budget
        # settings are then empty).
        csv_row combos "$COMBOS"
        csv_row cpus "$cpus"
        csv_row margin "$margin"
        csv_row max_jobs "$max_jobs"
        csv_row max_threads "$max_threads"
        csv_row repeats "$repeats"
        csv_row query_timeout "$QUERY_TIMEOUT"
    } > "$1"
}

# csv_row KEY VALUE: one key,value line with VALUE quoted for CSV.
csv_row() { printf '%s,"%s"\n' "$1" "${2//\"/\"\"}"; }

# Every run should return the same rows for a query; report any that don't,
# and write each query's outcome to OUT_DIR/check.csv for summarize_tpch.R:
#   same        every successful run returned identical output
#   reordered   same rows in a different order, in a query whose ORDER BY has
#               ties: Q11 orders by value alone, and at SF100 some parts share
#               a value, so a parallel sort may return those tied rows in any
#               order. (Q3, Q5, Q10 and Q18 order by a revenue or total price
#               with at most a date as tie-breaker, so they could tie too; no
#               ties were found at SF1 and they are assumed tie-free here, so
#               a tie in one of them would be reported as misordered.)
#   misordered  same rows in a different order, in a query whose ORDER BY
#               should fix the order (a bug, like differ)
#   single      only one successful run, so nothing to compare
#   differ      different rows
#   no_results  no successful run
# Only results with an exit 0 row in queries.csv are compared: runs where the
# query failed hold partial or no rows, and a result without a row (its shell
# was killed before writing it) can't be trusted either.
# Returns 1 if any query is differ or misordered.
check_results() {
    local q f files status differ=() reordered=() misordered=() single=() never_ok=()
    local -A ok=()
    while read -r f; do
        ok[$f]=1
    done < <(awk -F, 'NR > 1 && $5 == 0 {printf "j%02d_t%02d/r%d/q%02d.csv\n", $1, $2, $3, $4}' "$QUERIES_CSV")
    echo "query,status" > "$OUT_DIR/check.csv"
    for q in $(seq -f '%02g' 1 22); do
        files=()
        for f in "$OUT_DIR"/j[0-9][0-9]_t{[0-9][0-9],[0-9][0-9][0-9],[0-9][0-9][0-9][0-9]}/r*/"q$q.csv"; do
            [ -f "$f" ] && [ -n "${ok[${f#"$OUT_DIR"/}]:-}" ] && files+=("$f")
        done
        if (( ${#files[@]} == 0 )); then
            status=no_results; never_ok+=("Q$q")
        elif (( ${#files[@]} == 1 )); then
            status=single; single+=("Q$q")
        elif (( $(md5sum -- "${files[@]}" | awk '{print $1}' | sort -u | wc -l) == 1 )); then
            status=same
        elif (( $(for f in "${files[@]}"; do sort -- "$f" | md5sum; done | sort -u | wc -l) == 1 )); then
            if [ "$q" = 11 ]; then
                status=reordered; reordered+=("Q$q")
            else
                status=misordered; misordered+=("Q$q")
            fi
        else
            status=differ; differ+=("Q$q")
        fi
        echo "$((10#$q)),$status" >> "$OUT_DIR/check.csv"
    done
    (( ${#never_ok[@]} == 0 )) ||
        echo "Warning: ${never_ok[*]} succeeded in no run, so there are no results to compare" >&2
    (( ${#single[@]} == 0 )) ||
        echo "Warning: ${single[*]} succeeded in only one run, so there was nothing to compare" >&2
    (( ${#reordered[@]} == 0 )) ||
        echo "Note: ${reordered[*]} returned the same rows in every successful run, but rows with tied ORDER BY values came back in different orders"
    (( ${#misordered[@]} == 0 )) ||
        echo "Warning: ${misordered[*]} returned the same rows in different orders, although the ORDER BY has no ties (compare OUT_DIR/jNN_tNN/rN/qNN.csv)" >&2
    (( ${#differ[@]} == 0 )) ||
        echo "Warning: results differ between runs for ${differ[*]} (compare OUT_DIR/jNN_tNN/rN/qNN.csv)" >&2
    (( ${#never_ok[@]} + ${#single[@]} + ${#misordered[@]} + ${#differ[@]} == 0 )) &&
        echo "All 22 queries returned the same rows in every successful run"
    (( ${#misordered[@]} + ${#differ[@]} == 0 ))
}

repeats="${REPEATS:-3}"
is_pos_int "$repeats" || bad REPEATS "$repeats" "$POS_INT"
COMBOS="${COMBOS:-}"
# combos holds "threads jobs" pairs, in the order they run within a repeat.
combos=()
fallback=0
if [ -n "$COMBOS" ]; then
    # Explicit combinations; the budget settings don't apply.
    cpus="" max_jobs="" max_threads="" margin=""
    for v in CPUS MAX_JOBS MAX_THREADS MARGIN; do
        [ -z "${!v:-}" ] || echo "Warning: $v is ignored when COMBOS is set" >&2
    done
    # Split on IFS only, as for QUERY_ORDER.
    read -r -d '' -a pairs <<< "$COMBOS"
    for pair in "${pairs[@]}"; do
        [[ "$pair" =~ ^([1-9][0-9]{0,3})x([1-9][0-9]{0,3})$ ]] ||
            bad COMBOS "$pair" "space-separated NxT pairs like 4x21 (N and THREADS whole numbers, no leading zeros)"
        jobs=${BASH_REMATCH[1]}
        threads=${BASH_REMATCH[2]}
        (( jobs <= 22 )) || bad COMBOS "$pair" "pairs with N at most 22 (there are only 22 queries)"
        for combo in "${combos[@]}"; do
            [ "$combo" = "$threads $jobs" ] && { echo "COMBOS lists $pair more than once" >&2; usage; }
        done
        combos+=("$threads $jobs")
    done
    (( ${#combos[@]} > 0 )) || bad COMBOS "$COMBOS" "at least one NxT pair"
    sweep_desc="Running the combinations $COMBOS"
else
    cpus="${CPUS:-$(nproc)}"
    # Before the defaults below do arithmetic with it.
    is_pos_int "$cpus" || bad CPUS "$cpus" "$POS_INT"
    max_jobs="${MAX_JOBS:-$(( cpus < 22 ? cpus : 22 ))}"
    max_threads="${MAX_THREADS:-$cpus}"
    margin="${MARGIN:-0}"
    is_pos_int "$max_jobs" || bad MAX_JOBS "$max_jobs" "$POS_INT"
    is_pos_int "$max_threads" || bad MAX_THREADS "$max_threads" "$POS_INT"
    [[ "$margin" =~ ^(0|[1-9][0-9]{0,3})$ ]] || bad MARGIN "$margin" "a whole number from 0 to 9999 (no leading zeros)"
    (( max_jobs > 22 )) && max_jobs=22

    # "threads jobs" pairs with jobs + threads - 1 within margin of cpus,
    # threads-major. When even 22 jobs (all the queries) can't get within margin,
    # use 22 as the closest. A MAX_JOBS below 22 doesn't get that fallback: it
    # would bring in runs far below the CPU budget.
    skipped=()
    for threads in $(seq 1 "$max_threads"); do
        if (( max_jobs == 22 && max_jobs + threads - 1 < cpus - margin )); then
            combos+=("$threads $max_jobs")
            fallback=1
            continue
        fi
        found=0
        for jobs in $(seq 1 "$max_jobs"); do
            total=$(( jobs + threads - 1 ))
            (( total >= cpus - margin && total <= cpus + margin )) && combos+=("$threads $jobs") && found=1
        done
        (( found )) || skipped+=("$threads")
    done
    (( ${#combos[@]} > 0 )) || { echo "No combinations with jobs + threads - 1 within $margin of $cpus" >&2; die 2; }
    (( ${#skipped[@]} == 0 )) ||
        echo "Skipping threads ${skipped[*]}: no jobs value gives jobs + threads - 1 within $margin of $cpus (raise MARGIN, or MAX_JOBS if it is below 22, to include them)" >&2
    sweep_desc="Sweeping jobs 1..$max_jobs x threads 1..$max_threads where jobs + threads - 1 is $cpus +/- $margin $( (( fallback )) && echo "(or jobs = 22 where even that is below the budget) ")"
fi
# The largest N in the sweep, for the warm-up.
warm_jobs=1
for combo in "${combos[@]}"; do
    read -r threads jobs <<< "$combo"
    (( jobs > warm_jobs )) && warm_jobs=$jobs
done

# Check the server and warm up before touching the previous sweep's output,
# so a failure or Ctrl-C up to here leaves it intact.
threads_now=$(get_threads) || die 1
# A sweep that was killed outright (SIGKILL, power loss) leaves the server at
# its last THREADS, which this sweep then takes as the original.
is_pos_int "$threads_now" ||
    { echo "Unexpected threads setting from the server: '$threads_now'" >&2; die 1; }
original_threads=$threads_now
echo "Server threads = $original_threads (restored at the end)"
load_q11

# OUT_DIR must be writable before the warm-up, so a bad OUT_DIR doesn't cost
# a full pass over the queries. Nothing of the previous sweep is touched (an
# OUT_DIR that didn't exist is created, empty).
mkdir -p -- "$OUT_DIR" || { echo "Failed to create $OUT_DIR" >&2; die 1; }
write_test=$(mktemp -- "$OUT_DIR/.write_test.XXXXXX") || { echo "Cannot write to $OUT_DIR" >&2; die 1; }
rm -f -- "$write_test"

# Warm up with the server's current threads setting and the sweep's largest N.
warm_up "$warm_jobs" "$original_threads"

# Remove result folders from earlier sweeps (possibly with other CPUS or
# MARGIN) so everything under OUT_DIR matches the new CSVs. Only exact
# jNN_tNN names are removed (tNNN, tNNNN for THREADS >= 100), not e.g. a kept
# copy named j06_t04_baseline.
# The previous check.csv goes too, so an interrupted sweep has none, and so
# do summarize_tpch.R's summary.png and summary.pdf, which describe the old
# sweep.
# Stop here if OUT_DIR can't be written, rather than sweeping for nothing.
mkdir -p -- "$OUT_DIR" || { echo "Failed to create $OUT_DIR" >&2; die 1; }
rm -rf -- "$OUT_DIR"/j[0-9][0-9]_t{[0-9][0-9],[0-9][0-9][0-9],[0-9][0-9][0-9][0-9]} \
    "$OUT_DIR/check.csv" "$OUT_DIR/summary.png" "$OUT_DIR/summary.pdf"

RUNS_CSV="$OUT_DIR/runs.csv"
QUERIES_CSV="$OUT_DIR/queries.csv"
{ write_system_info "$OUT_DIR/system.csv" &&
    echo "jobs,threads,rep,seconds,failed" > "$RUNS_CSV" &&
    echo "jobs,threads,rep,query,exit,start_s,seconds,query_s" > "$QUERIES_CSV"; } ||
    { echo "Failed to write to $OUT_DIR" >&2; die 1; }

echo "$sweep_desc (${#combos[@]} combinations x $repeats repeats)"
total_failed=0
current_threads=""
for rep in $(seq 1 "$repeats"); do
    for (( i = 0; i < ${#combos[@]}; i++ )); do
        if (( rep % 2 )); then
            combo=${combos[i]}
        else
            combo=${combos[${#combos[@]} - 1 - i]}
        fi
        read -r threads jobs <<< "$combo"
        if [ "$threads" != "$current_threads" ]; then
            set_threads "$threads"
            current_threads=$threads
        fi
        echo "=== jobs=$jobs threads=$threads repeat=$rep/$repeats ==="
        run_benchmark "$(printf '%s/j%02d_t%02d/r%d' "$OUT_DIR" "$jobs" "$threads" "$rep")" "$jobs" "$threads" "$rep"
        total_failed=$((total_failed + FAILED))
    done
done
echo "Sweep done ($total_failed failed queries). Timings in $RUNS_CSV and $QUERIES_CSV"
check_results
check_rc=$?
die $(( total_failed > 0 || check_rc != 0 ))
