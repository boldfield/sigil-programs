#!/bin/bash
set -e

# Create a temp directory with a test file
tmpdir=$(mktemp -d)
trap 'rm -rf $tmpdir; kill $server_pid $server10_pid 2>/dev/null || true' EXIT

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

# Start a second fixture server instance that advertises HTTP/1.0, serving
# the same directory. It closes the connection after every response (the
# legitimate close-delimited framing), used below for the differential
# HTTP/1.1-vs-HTTP/1.0 test and the close-delimited fallback test.
portfile10=$(mktemp)
python3 surl/fixture.py "$tmpdir" "HTTP/1.0" > "$portfile10" 2>&1 &
server10_pid=$!

for i in {1..50}; do
  if [ -s "$portfile10" ]; then
    port10=$(cat "$portfile10")
    break
  fi
  sleep 0.01
done

if [ -z "$port10" ]; then
  echo "Failed to get port from HTTP/1.0 fixture server"
  exit 1
fi

# Fetch with surl
surl_response=$(timeout 10 bin/main "http://127.0.0.1:$port/test.txt")

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

# Test chunked response: Transfer-Encoding: chunked must be read to the
# terminating zero-length chunk, not to connection close.
surl_chunked=$(timeout 10 bin/main "http://127.0.0.1:$port/chunked")
curl_chunked=$(curl -s "http://127.0.0.1:$port/chunked")

if [ "$surl_chunked" = "$curl_chunked" ]; then
  echo "✓ surl chunked response matches curl"
else
  echo "✗ surl chunked response does not match curl"
  echo "  surl: '$surl_chunked'"
  echo "  curl: '$curl_chunked'"
  exit 1
fi

# Test non-canonical header casing on the framing headers themselves:
# HTTP field names are case-insensitive (RFC 9110 §5.1), and a server
# that sends "content-length"/"transfer-encoding" in lowercase is just
# as legitimate as one that sends the canonical casing. surl previously
# matched those two names exactly, so a lowercase field name read as "no
# framing declared" and either hung waiting for EOF that never came or
# silently dropped the body.
surl_length_lower=$(timeout 10 bin/main "http://127.0.0.1:$port/length-lower")
curl_length_lower=$(curl -s "http://127.0.0.1:$port/length-lower")

if [ "$surl_length_lower" = "$curl_length_lower" ]; then
  echo "✓ surl matches curl against a lowercase content-length header"
else
  echo "✗ surl does not match curl against a lowercase content-length header"
  echo "  surl: '$surl_length_lower'"
  echo "  curl: '$curl_length_lower'"
  exit 1
fi

surl_chunked_lower=$(timeout 10 bin/main "http://127.0.0.1:$port/chunked-lower")
curl_chunked_lower=$(curl -s "http://127.0.0.1:$port/chunked-lower")

if [ "$surl_chunked_lower" = "$curl_chunked_lower" ]; then
  echo "✓ surl matches curl against a lowercase transfer-encoding header"
else
  echo "✗ surl does not match curl against a lowercase transfer-encoding header"
  echo "  surl: '$surl_chunked_lower'"
  echo "  curl: '$curl_chunked_lower'"
  exit 1
fi

# Test close-delimited response (no Content-Length, not chunked) against
# the HTTP/1.0 server: the only legitimate way to delimit this body is the
# connection closing, and surl must still return rather than hang.
surl_close_delim=$(timeout 10 bin/main "http://127.0.0.1:$port10/close-delim")
curl_close_delim=$(curl -s "http://127.0.0.1:$port10/close-delim")

if [ "$surl_close_delim" = "$curl_close_delim" ]; then
  echo "✓ surl HTTP/1.0 close-delimited response matches curl"
else
  echo "✗ surl HTTP/1.0 close-delimited response does not match curl"
  echo "  surl: '$surl_close_delim'"
  echo "  curl: '$curl_close_delim'"
  exit 1
fi

# Differential test: the same binary, the same body, differing only in the
# server's advertised protocol version. This is the exact reproduction
# that exposed the HTTP/1.1 keep-alive hang (see
# docs/fixes/surl-http11-keepalive-hang.md) — the HTTP/1.0 server closes
# after every response and always worked, while the HTTP/1.1 server keeps
# the connection open and used to hang forever. Both must return and match
# curl's body.
surl_11=$(timeout 10 bin/main "http://127.0.0.1:$port/test.txt")
surl_10=$(timeout 10 bin/main "http://127.0.0.1:$port10/test.txt")

if [ "$surl_11" = "$curl_response" ] && [ "$surl_10" = "$curl_response" ]; then
  echo "✓ surl matches curl against both an HTTP/1.1 keep-alive server and an HTTP/1.0 close-delimited server"
else
  echo "✗ surl differential HTTP/1.1 vs HTTP/1.0 test failed"
  echo "  HTTP/1.1: '$surl_11'"
  echo "  HTTP/1.0: '$surl_10'"
  echo "  expected: '$curl_response'"
  exit 1
fi

# Test -X POST (POST to /test.txt returns same content as GET)
surl_post=$(timeout 10 bin/main -X POST "http://127.0.0.1:$port/test.txt" 2>&1)
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
surl_header=$(timeout 10 bin/main -H "X-Custom: test-value" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "x-custom" || true)
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
timeout 10 bin/main -d "hello world" "http://127.0.0.1:$port/echo" > "$tmpdir/surl_d.out"
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
surl_head=$(timeout 10 bin/main -I "http://127.0.0.1:$port/test.txt")
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
stdout_capture=$(timeout 10 bin/main -o "$outfile" "http://127.0.0.1:$port/test.txt")

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

# Test -L (follow redirects): without -L, should get 302; with -L, should reach final target
surl_no_follow=$(timeout 10 bin/main "http://127.0.0.1:$port/a" 2>&1)
curl_no_follow=$(curl -s "http://127.0.0.1:$port/a" 2>&1)

if [ "$surl_no_follow" = "$curl_no_follow" ]; then
  echo "✓ surl without -L returns 302 response body (empty)"
else
  echo "✗ surl without -L does not match curl"
  echo "  surl: '$surl_no_follow'"
  echo "  curl: '$curl_no_follow'"
  exit 1
fi

surl_follow=$(timeout 10 bin/main -L "http://127.0.0.1:$port/a" 2>&1)
curl_follow=$(curl -sL "http://127.0.0.1:$port/a" 2>&1)

if [ "$surl_follow" = "$curl_follow" ]; then
  echo "✓ surl -L follows redirects to final target"
else
  echo "✗ surl -L does not match curl"
  echo "  surl: '$surl_follow'"
  echo "  curl: '$curl_follow'"
  exit 1
fi

# Test -u (Basic auth): check Authorization header is sent correctly
surl_auth=$(timeout 10 bin/main -u "user:password" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "^Authorization:" || true)
curl_auth=$(curl -s -u "user:password" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "^Authorization:" || true)

if [ "$surl_auth" = "$curl_auth" ]; then
  echo "✓ surl -u Authorization header matches curl"
else
  echo "✗ surl -u Authorization header does not match curl"
  echo "  surl: '$surl_auth'"
  echo "  curl: '$curl_auth'"
  exit 1
fi

# Test -b (Cookie): check Cookie header is sent correctly
surl_cookie=$(timeout 10 bin/main -b "sessionid=abc123" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "^Cookie:" || true)
curl_cookie=$(curl -s -b "sessionid=abc123" "http://127.0.0.1:$port/headers" 2>&1 | grep -i "^Cookie:" || true)

if [ "$surl_cookie" = "$curl_cookie" ]; then
  echo "✓ surl -b Cookie header matches curl"
else
  echo "✗ surl -b Cookie header does not match curl"
  echo "  surl: '$surl_cookie'"
  echo "  curl: '$curl_cookie'"
  exit 1
fi

# Test -c (save cookies to jar): Set-Cookie headers are saved to file, one per line
jar_file="$tmpdir/cookies.jar"
timeout 10 bin/main -c "$jar_file" "http://127.0.0.1:$port/cookies" > /dev/null

if [ ! -f "$jar_file" ]; then
  echo "✗ surl -c did not create jar file"
  exit 1
fi
jar_content=$(cat "$jar_file")
if [[ "$jar_content" == *"sessionid=abc123"* ]] && [[ "$jar_content" == *"tracking=xyz789"* ]]; then
  echo "✓ surl -c saves Set-Cookie headers to jar file"
else
  echo "✗ surl -c jar file does not contain expected cookies"
  echo "  jar content: '$jar_content'"
  exit 1
fi

# Test -c with non-canonical header casing: a lowercase set-cookie response
# header must be saved too (HTTP field names are case-insensitive).
jar_file_lower="$tmpdir/cookies-lower.jar"
timeout 10 bin/main -c "$jar_file_lower" "http://127.0.0.1:$port/cookies-lower" > /dev/null

jar_lower_content=$(cat "$jar_file_lower" 2>/dev/null || true)
if [[ "$jar_lower_content" == *"lowered=case42"* ]]; then
  echo "✓ surl -c saves lowercase set-cookie header to jar file"
else
  echo "✗ surl -c jar file does not contain cookie from lowercase set-cookie header"
  echo "  jar content: '$jar_lower_content'"
  exit 1
fi

# Test -v (verbose: request/response headers to stderr, body to stdout unchanged)
stderr_file="$tmpdir/verbose_stderr.out"
stdout_file="$tmpdir/verbose_stdout.out"

timeout 10 bin/main -v "http://127.0.0.1:$port/test.txt" >"$stdout_file" 2>"$stderr_file"

# Check that body is on stdout (unchanged)
stdout_content=$(cat "$stdout_file")
expected_body=$(curl -s "http://127.0.0.1:$port/test.txt")
if [ "$stdout_content" = "$expected_body" ]; then
  echo "✓ surl -v body on stdout unchanged"
else
  echo "✗ surl -v body on stdout not as expected"
  echo "  expected: '$expected_body'"
  echo "  got:      '$stdout_content'"
  exit 1
fi

# Check that stderr contains verbose markers (> for request, < for response)
stderr_content=$(cat "$stderr_file")
if [[ "$stderr_content" == *">"* ]] && [[ "$stderr_content" == *"<"* ]]; then
  echo "✓ surl -v has verbose output on stderr (> and < prefixes)"
else
  echo "✗ surl -v missing verbose markers on stderr"
  echo "  stderr: '$stderr_content'"
  exit 1
fi

# Check that request line is present (GET ... HTTP/1.1)
if [[ "$stderr_content" == *"GET"* ]] && [[ "$stderr_content" == *"HTTP/1.1"* ]]; then
  echo "✓ surl -v has request line with method and HTTP version"
else
  echo "✗ surl -v missing request line"
  echo "  stderr: '$stderr_content'"
  exit 1
fi

# Stop the HTTP/1.0 server (no graceful-shutdown assertion needed for it;
# the trap on EXIT also covers it as a backstop)
kill -TERM $server10_pid 2>/dev/null || true

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
