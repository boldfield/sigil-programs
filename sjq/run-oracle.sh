#!/bin/bash
set -e

SJQ="./bin/sjq"

# Test 1: JSON identity filter (round-trip)
echo "  test: identity filter with simple JSON"
result=$(echo '{"key":"value"}' | "$SJQ" '.')
if [ "$result" = '{"key":"value"}' ]; then
  echo "    PASS"
else
  echo "    FAIL: expected {'key':'value'}, got '$result'"
  exit 1
fi

# Test 2: Array JSON identity filter
echo "  test: identity filter with array"
result=$(echo '[1,2,3]' | "$SJQ" '.')
if [ "$result" = '[1,2,3]' ]; then
  echo "    PASS"
else
  echo "    FAIL: expected [1,2,3], got '$result'"
  exit 1
fi

# Test 3: Null JSON
echo "  test: identity filter with null"
result=$(echo 'null' | "$SJQ" '.')
if [ "$result" = 'null' ]; then
  echo "    PASS"
else
  echo "    FAIL: expected null, got '$result'"
  exit 1
fi

# Test 4: Non-identity filter should error
echo "  test: non-identity filter errors"
if "$SJQ" '.foo' <<< '{"foo":"bar"}' 2>/dev/null; then
  echo "    FAIL: expected non-zero exit code"
  exit 1
else
  echo "    PASS"
fi

# Test 5: Invalid JSON should error
echo "  test: invalid JSON errors"
if echo 'not json' | "$SJQ" '.' 2>/dev/null; then
  echo "    FAIL: expected non-zero exit code for invalid JSON"
  exit 1
else
  echo "    PASS"
fi

echo "  oracle: all tests passed"
