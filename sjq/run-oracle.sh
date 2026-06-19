#!/bin/bash
set -euo pipefail

# Identity filter round-trip: integer
out=$(echo '42' | bin/main '.')
[ "$out" = "42" ] || { echo "oracle FAIL: identity int: expected '42', got '$out'"; exit 1; }

# Identity filter round-trip: string
out=$(echo '"hello"' | bin/main '.')
[ "$out" = '"hello"' ] || { echo "oracle FAIL: identity string: expected '\"hello\"', got '$out'"; exit 1; }

# Identity filter round-trip: null
out=$(echo 'null' | bin/main '.')
[ "$out" = "null" ] || { echo "oracle FAIL: identity null: expected 'null', got '$out'"; exit 1; }

# Non-identity filter must exit non-zero
if echo '42' | bin/main '.foo' >/dev/null 2>&1; then
  echo "oracle FAIL: .foo filter should exit non-zero"
  exit 1
fi

echo "oracle: sjq ok"
