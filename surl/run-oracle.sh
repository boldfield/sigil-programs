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

# Compare surl's GET output against curl's, byte for byte, with NO masking.
#
# surl emits the response body followed by exactly one '\n', and that newline
# is forced by the Sigil runtime — it is not something we can drop here. The
# std.io stdout is a Rust LineWriter that flushes only on a newline, so a body
# printed without a trailing newline (IO.print) stays buffered and never
# reaches the pipe — the body is lost entirely. main.sigil therefore uses
# IO.println, which flushes the body at the cost of one trailing newline that
# `curl -s` never adds. Byte-exact equality with curl is thus impossible; the
# precise, true relationship is: surl output == curl output + one '\n'.
#
# We assert exactly that, comparing raw bytes with `cmp` instead of letting
# `$(...)` silently strip trailing newlines from both sides. That keeps the
# oracle honest: the single runtime-mandated newline is the ONLY tolerated
# difference, so a missing/garbled body, an extra newline, or trailing
# whitespace all still fail the check.
surl_out="$tmpdir/surl.out"
curl_out="$tmpdir/curl.out"
expected="$tmpdir/expected.out"

"$surl_bin" "$url" > "$surl_out"
curl -s "$url" > "$curl_out"

# expected = curl's body plus the single trailing newline surl's println adds.
cat "$curl_out" > "$expected"
printf '\n' >> "$expected"

if ! cmp -s "$surl_out" "$expected"; then
  echo "ERROR: surl output does not match curl output (+ one trailing newline)"
  echo "--- surl output (od -c) ---"
  od -c "$surl_out"
  echo "--- curl output (od -c) ---"
  od -c "$curl_out"
  exit 1
fi

echo "  surl GET body matches curl (modulo surl's single trailing newline)"
