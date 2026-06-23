#!/bin/bash
set -e

# Find a free port using Python's socket module (works without lsof)
find_free_port() {
  python3 -c "import socket; s = socket.socket(); s.bind(('', 0)); print(s.getsockname()[1]); s.close()"
}

# Capture repo root before changing directories
root=$(pwd)

# Create temporary directory for the test
tmpdir=$(mktemp -d)
trap 'kill $server_pid 2>/dev/null; rm -rf "$tmpdir"' EXIT

# Create a test file with known content
test_content="Hello from Oracle Test"
echo -n "$test_content" > "$tmpdir/file"

# Find a free port
port=$(find_free_port)

# Start HTTP server in the background (in subshell so we stay at repo root)
(cd "$tmpdir" && python3 -m http.server "$port" >/dev/null 2>&1) &
server_pid=$!

# Poll for server readiness with timeout (up to 5 seconds)
max_attempts=50
attempt=0
while [ $attempt -lt $max_attempts ]; do
  if curl -s "http://127.0.0.1:$port/file" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
  echo "ERROR: server did not become ready within 5 seconds"
  exit 1
fi

# Test surl output
surl_output=$("$root/bin/main" "http://127.0.0.1:$port/file")

# Test curl output
curl_output=$(curl -s "http://127.0.0.1:$port/file")

# Compare outputs
if [ "$surl_output" != "$curl_output" ]; then
  echo "ERROR: surl output does not match curl output"
  echo "surl output: '$surl_output'"
  echo "curl output: '$curl_output'"
  exit 1
fi
