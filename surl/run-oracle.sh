#!/bin/bash
# surl curl-oracle: stand up a local fixture HTTP server, then assert that
# `surl http://127.0.0.1:PORT/file` produces the same body as `curl -s` of
# the same URL. Exit non-zero on any mismatch. Invoked by the Makefile
# test-% hook from the repo root.
set -euo pipefail

# Repo root, captured BEFORE any cd: the Makefile builds surl/main.sigil to
# bin/main (basename of the .sigil entry), and runs this script from the
# repo root. Resolve the binary by absolute path so launching the fixture
# server (which we do from a temp dir) cannot break the surl invocation.
root="$(pwd)"
surl_bin="$root/bin/main"

if [ ! -x "$surl_bin" ]; then
  echo "ERROR: surl binary not found at $surl_bin (did 'make test-surl' build it?)"
  exit 1
fi

# Pick a free TCP port via Python's socket module (no lsof dependency).
find_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

tmpdir="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Fixture file with known content (no trailing newline).
test_content="Hello from Oracle Test"
printf '%s' "$test_content" > "$tmpdir/file"

port="$(find_free_port)"
url="http://127.0.0.1:$port/file"

# Serve the fixture dir in a subshell so this script stays at the repo root.
( cd "$tmpdir" && exec python3 -m http.server "$port" >/dev/null 2>&1 ) &
server_pid=$!

# Actively poll until the server accepts a connection (avoids a startup race
# that a fixed sleep would not reliably cover). Up to ~5s.
ready=0
for _ in $(seq 1 50); do
  if curl -s "$url" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  echo "ERROR: fixture server did not become ready on port $port"
  exit 1
fi

# Compare surl's GET body against curl's. Command substitution strips
# trailing newlines on both sides, so surl's trailing newline (it prints the
# body with a newline) does not cause a spurious mismatch.
surl_output="$("$surl_bin" "$url")"
curl_output="$(curl -s "$url")"

if [ "$surl_output" != "$curl_output" ]; then
  echo "ERROR: surl output does not match curl output"
  echo "surl output: '$surl_output'"
  echo "curl output: '$curl_output'"
  exit 1
fi

echo "  surl GET body matches curl: '$surl_output'"
