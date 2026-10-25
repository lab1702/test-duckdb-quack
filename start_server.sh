#!/usr/bin/env bash
# Start a read-only DuckDB quack server for the TPC-H database.
# Usage: ./start_server.sh DATABASE-FILE
# The server stops when this process does: Ctrl-D or `.quit` at its prompt, or
# kill its PID. Ctrl-C only interrupts a running statement (the duckdb shell
# ignores it at the prompt), so it does not stop the server. Run it in
# the foreground of its own terminal, or in the background with stdin
# redirected (e.g. `./start_server.sh db.duckdb < /dev/null > /dev/null
# 2> server.log &`); backgrounding it with `&` from an interactive shell
# without redirecting stdin stops it (SIGTTIN) as soon as it reads the
# terminal. A background job still dies with its terminal (bash resends the
# SIGHUP it gets to its jobs), so a server that must outlive the terminal or
# an ssh session needs `nohup` or `setsid -f` in front of the command, or
# `disown` after it.
# The first line the server prints is its listen table, with the quack auth
# token, so a log that stdout is redirected to holds the token: keep it
# private, or send stdout to /dev/null and log only stderr, as above.
# -readonly protects the database file only: any local client that can
# connect can still read and write files as this user, load extensions and
# change the server's settings (run_tpch.sh relies on SET threads).
set -eu

if [ $# -ne 1 ]; then
    echo "Usage: $0 DATABASE-FILE" >&2
    exit 2
fi
DB="$1"
# Keep a file name starting with '-' from being read as an option.
case "$DB" in -*) DB="./$DB" ;; esac

if [ ! -f "$DB" ]; then
    echo "Database file not found: $DB" >&2
    exit 1
fi

# After -serve, duckdb runs its shell on stdin and exits at end of input, which
# from /dev/null, a pipe or a service manager is immediately. Off a terminal,
# give it a stdin that never ends: a FIFO opened read-write (so it never sees
# EOF; Linux semantics), removed straight away. The FIFO goes in a private
# folder from mktemp -d, so no other user can create or swap it.
if [ ! -t 0 ]; then
    fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/start_server.XXXXXX")
    trap 'rm -rf -- "$fifo_dir"' EXIT
    mkfifo -m 600 "$fifo_dir/fifo"
    exec 0<> "$fifo_dir/fifo"
    rm -rf -- "$fifo_dir"
    trap - EXIT
fi

# -no-init: a ~/.duckdbrc could change where the server listens
# (.serve_command) or its settings (e.g. SET threads, which run_tpch.sh treats
# as the original value to restore).
exec duckdb -no-agent -no-init "$DB" -readonly -serve
