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
#
# Byte-level comparison (cmp), NOT `$(...)`: the /echo body "hello world" has
# no trailing newline, and `$(...)` strips trailing newlines on both sides,
# which would mask an off-by-a-newline (or empty-body) bug. Both outputs are
# written to files and compared byte-for-byte instead.
#
# surl terminates its output with exactly one newline — std.io's `println` is
# the only exit-flushing primitive on this toolchain (plain `print` never
# flushes, so a body without a final newline is silently dropped; see
# main.sigil). So the expected bytes are curl's body PLUS one "\n"; append it
# to curl's capture before comparing. This still catches a missing/empty body,
# a duplicated body, or any spurious extra bytes.
bin/main -d "hello world" "http://127.0.0.1:$port/echo" > "$tmpdir/surl_d.out"
curl -s -d "hello world" "http://127.0.0.1:$port/echo" > "$tmpdir/curl_d.out"
printf '\n' >> "$tmpdir/curl_d.out"

if cmp -s "$tmpdir/surl_d.out" "$tmpdir/curl_d.out"; then
  echo "✓ surl -d data matches curl (body byte-for-byte, one trailing newline)"
else
  echo "✗ surl -d data does not match curl"
  echo "  surl:          '$(cat "$tmpdir/surl_d.out")'"
  echo "  curl (+ \\n):    '$(cat "$tmpdir/curl_d.out")'"
  exit 1
fi

# Test -I (HEAD request - status + headers only)
surl_head=$(bin/main -I "http://127.0.0.1:$port/test.txt" 2>&1)
curl_head=$(curl -sI "http://127.0.0.1:$port/test.txt" 2>&1)

# Extract status line from both outputs for comparison
surl_status=$(echo "$surl_head" | head -1)
curl_status=$(echo "$curl_head" | head -1)

# Extract Content-Type header from both outputs for comparison
surl_content_type=$(echo "$surl_head" | grep -i "^content-type:" || true)
curl_content_type=$(echo "$curl_head" | grep -i "^content-type:" || true)

if [ "$surl_status" = "$curl_status" ] && [ "$surl_content_type" = "$curl_content_type" ]; then
  echo "✓ surl -I status + headers matches curl"
else
  echo "✗ surl -I status + headers does not match curl"
  echo "  surl status:  '$surl_status'"
  echo "  curl status:  '$curl_status'"
  echo "  surl c-type:  '$surl_content_type'"
  echo "  curl c-type:  '$curl_content_type'"
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
