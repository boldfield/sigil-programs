#!/bin/bash
set -e

# Create a temp directory with a test file
tmpdir=$(mktemp -d)
trap 'rm -rf $tmpdir; kill $server_pid 2>/dev/null || true' EXIT

echo "test content" > "$tmpdir/test.txt"

# Start the fixture server and capture port from stdout
portfile=$(mktemp)
python3 surl/fixture.py "$tmpdir" > "$portfile" 2>&1 &
server_pid=$!

# Read the port (wait for it to be written)
for i in {1..50}; do
  if [ -s "$portfile" ]; then
    port=$(cat "$portfile")
    break
  fi
  sleep 0.01
done

if [ -z "$port" ]; then
  echo "Failed to get port from fixture server"
  exit 1
fi

# Fetch with surl
surl_response=$(bin/main "http://127.0.0.1:$port/test.txt")

# Fetch with curl for comparison
curl_response=$(curl -s "http://127.0.0.1:$port/test.txt")

# Compare responses
if [ "$surl_response" = "$curl_response" ]; then
  echo "✓ surl GET body matches curl"
else
  echo "✗ surl GET body does not match curl"
  echo "  surl: '$surl_response'"
  echo "  curl: '$curl_response'"
  exit 1
fi

# Test -X POST (POST to /test.txt returns same content as GET)
surl_post=$(bin/main -X POST "http://127.0.0.1:$port/test.txt" 2>&1)
curl_post=$(curl -s -X POST "http://127.0.0.1:$port/test.txt" 2>&1)

if [ "$surl_post" = "$curl_post" ]; then
  echo "✓ surl -X POST matches curl"
else
  echo "✗ surl -X POST does not match curl"
  echo "  surl: '$surl_post'"
  echo "  curl: '$curl_post'"
  exit 1
fi

# Test -H header
surl_header=$(bin/main -H "X-Custom: test-value" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "x-custom" || true)
curl_header=$(curl -s -H "X-Custom: test-value" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "x-custom" || true)

if [ "$surl_header" = "$curl_header" ]; then
  echo "✓ surl -H header matches curl"
else
  echo "✗ surl -H header does not match curl"
  echo "  surl: '$surl_header'"
  echo "  curl: '$curl_header'"
  exit 1
fi

# Test -d data (implies POST; /echo echoes the request body back).
# Byte-level comparison: the /echo body "hello world" has no trailing
# newline, so surl must reproduce curl's output EXACTLY (no appended "\n").
# `$(...)` would strip trailing newlines and mask such a mismatch, so both
# outputs are written to files and compared with `cmp`.
bin/main -d "hello world" "http://127.0.0.1:$port/echo" > "$tmpdir/surl_d.out"
curl -s -d "hello world" "http://127.0.0.1:$port/echo" > "$tmpdir/curl_d.out"

if cmp -s "$tmpdir/surl_d.out" "$tmpdir/curl_d.out"; then
  echo "✓ surl -d data matches curl (byte-for-byte)"
else
  echo "✗ surl -d data does not match curl"
  echo "  surl: '$(cat "$tmpdir/surl_d.out")'"
  echo "  curl: '$(cat "$tmpdir/curl_d.out")'"
  exit 1
fi

# Stop the server with SIGTERM
kill -TERM $server_pid 2>/dev/null || true

# Wait for it to stop (with timeout to avoid hanging)
(sleep 2 && kill -9 $server_pid 2>/dev/null) &
timeout_pid=$!

if wait $server_pid 2>/dev/null; then
  kill -9 $timeout_pid 2>/dev/null || true
else
  # Server didn't exit cleanly
  kill -9 $server_pid 2>/dev/null || true
  kill -9 $timeout_pid 2>/dev/null || true
  exit 1
fi
