#!/bin/bash
set -e

# Create a temp directory with a test file
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir; kill $server_pid 2>/dev/null || true" EXIT

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

# Test: fetch the file from the server
response=$(curl -s "http://127.0.0.1:$port/test.txt")

# Verify the content
if [ "$response" = "test content" ]; then
  echo "✓ fixture server works"
else
  echo "✗ fixture server returned wrong content: $response"
  exit 1
fi

# Stop the server with SIGTERM
kill -TERM $server_pid 2>/dev/null || true

# Wait for it to stop (with timeout to avoid hanging)
(sleep 2 && kill -9 $server_pid 2>/dev/null) &
timeout_pid=$!

if wait $server_pid 2>/dev/null; then
  kill -9 $timeout_pid 2>/dev/null || true
  echo "✓ fixture server stopped cleanly"
else
  # Server didn't exit cleanly
  kill -9 $server_pid 2>/dev/null || true
  kill -9 $timeout_pid 2>/dev/null || true
  exit 1
fi
