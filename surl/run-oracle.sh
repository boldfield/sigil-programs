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

# Test -I (HEAD: compare status line and Content-type header value to curl)
# Use tr -d '\r' to strip carriage returns from curl's CRLF-terminated output.
surl_head=$(bin/main -I "http://127.0.0.1:$port/test.txt")
curl_head=$(curl -sI "http://127.0.0.1:$port/test.txt" | tr -d '\r')

surl_status=$(echo "$surl_head" | head -1)
curl_status=$(echo "$curl_head" | head -1)

if [ "$surl_status" = "$curl_status" ]; then
  echo "✓ surl -I status line matches curl: $surl_status"
else
  echo "✗ surl -I status line does not match curl"
  echo "  surl: '$surl_status'"
  echo "  curl: '$curl_status'"
  exit 1
fi

surl_ct=$(echo "$surl_head" | grep -i "^Content-type:" | head -1 | cut -d: -f2- | sed 's/^ *//')
curl_ct=$(echo "$curl_head" | grep -i "^Content-type:" | head -1 | cut -d: -f2- | sed 's/^ *//')

if [ "$surl_ct" = "$curl_ct" ]; then
  echo "✓ surl -I Content-type matches curl: $surl_ct"
else
  echo "✗ surl -I Content-type does not match curl"
  echo "  surl: '$surl_ct'"
  echo "  curl: '$curl_ct'"
  exit 1
fi

# Test -o FILE: body written to file, nothing on stdout
outfile="$tmpdir/surl_o.out"
curl_body=$(curl -s "http://127.0.0.1:$port/test.txt")
stdout_capture=$(bin/main -o "$outfile" "http://127.0.0.1:$port/test.txt")

if [ -n "$stdout_capture" ]; then
  echo "✗ surl -o produced stdout output: '$stdout_capture'"
  exit 1
fi

surl_o_content=$(cat "$outfile" 2>/dev/null || true)
if [ "$surl_o_content" = "$curl_body" ]; then
  echo "✓ surl -o writes body to file, nothing to stdout"
else
  echo "✗ surl -o file contents don't match curl"
  echo "  expected: '$curl_body'"
  echo "  got:      '$surl_o_content'"
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
