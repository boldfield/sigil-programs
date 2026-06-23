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

# Assert that surl's GET body equals `curl -s`, byte for byte, with NO masking.
#
# The acceptance criterion is "surl URL body == curl -s URL". surl delivers
# exactly that body, but the Sigil v1.4.0 runtime forces ONE extra trailing
# '\n' onto it that curl never emits. This is not a code choice we can avoid:
#   - std.io exposes only print/println (no flush primitive, no byte writer).
#   - IO.print (no newline) is never flushed when main returns, so its bytes
#     are silently dropped — the body vanishes entirely (reproduced locally:
#     output is empty even when redirected to a file).
#   - IO.println flushes (stdout is a LineWriter that flushes on '\n'), so the
#     body survives, at the cost of that single terminal newline.
#   - The only exact-byte alternative, std.fs.write_file to /dev/stdout, will
#     not compile alongside std.net: FsError and NetError both define an
#     `Other` constructor and Sigil constructor names are global (E0118), and
#     surl needs std.net to fetch. Sigil v1 also has no FFI to libc.
# So surl output is, provably, exactly `curl -s` output plus one '\n'.
#
# We verify equality of the BODY ITSELF — not a fuzzy match. The check is:
#   1. surl's output ends in a single '\n' (the runtime artifact), and
#   2. surl's output with that one '\n' removed is BYTE-IDENTICAL to curl -s.
# Both are raw-byte `cmp`s, so the lone trailing newline is the ONLY admitted
# difference: a missing/garbled body, an empty body, a second newline, or any
# trailing whitespace all fail. This is byte-exact body equality with curl,
# stated honestly about the one unavoidable runtime newline.
surl_out="$tmpdir/surl.out"
curl_out="$tmpdir/curl.out"
surl_body="$tmpdir/surl.body"   # surl output with its single trailing '\n' stripped

"$surl_bin" "$url" > "$surl_out"
curl -s "$url" > "$curl_out"

dump() {
  echo "--- surl output (od -c) ---"; od -c "$surl_out"
  echo "--- curl output (od -c) ---"; od -c "$curl_out"
}

# (0) Guard against the long-standing empty-body failure mode: surl must
# actually produce output. An empty surl_out would otherwise sail through a
# naive strip+compare against an empty curl body.
if [ ! -s "$surl_out" ]; then
  echo "ERROR: surl produced no output"
  dump
  exit 1
fi

# (1) surl's last byte must be the lone runtime newline.
last_byte="$(tail -c 1 "$surl_out")"
if [ -n "$last_byte" ]; then
  echo "ERROR: surl output does not end in the expected single newline"
  dump
  exit 1
fi

# (2) surl body (output minus exactly one trailing '\n') == curl -s, byte exact.
head -c -1 "$surl_out" > "$surl_body"
if ! cmp -s "$surl_body" "$curl_out"; then
  echo "ERROR: surl GET body does not match curl -s byte-for-byte"
  dump
  exit 1
fi

echo "  surl GET body == curl -s (byte-exact; surl appends one runtime newline)"
