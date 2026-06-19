#!/bin/bash
set -e

SJQ="./bin/main"

# Test 1: JSON identity filter (round-trip)
echo "  test: identity filter with simple JSON"
result=$(echo '{"key":"value"}' | "$SJQ" '.')
if [ "$result" = '{"key": "value"}' ]; then
  echo "    PASS"
else
  echo "    FAIL: expected {'key': 'value'}, got '$result'"
  exit 1
fi

# Test 2: Array JSON identity filter
echo "  test: identity filter with array"
result=$(echo '[1,2,3]' | "$SJQ" '.')
if [ "$result" = '[1, 2, 3]' ]; then
  echo "    PASS"
else
  echo "    FAIL: expected [1, 2, 3], got '$result'"
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

# Test 4: Field access filter
echo "  test: field access filter"
result=$(echo '{"foo":"bar"}' | "$SJQ" '.foo')
if [ "$result" = '"bar"' ]; then
  echo "    PASS"
else
  echo "    FAIL: expected \"bar\", got '$result'"
  exit 1
fi

# Test 5: Array iteration filter
echo "  test: array iteration filter"
result=$(echo '[1,2,3]' | "$SJQ" '.[]')
expected="1
2
3"
if [ "$result" = "$expected" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected multi-line output, got '$result'"
  exit 1
fi

# Test 6: Invalid JSON should error
echo "  test: invalid JSON errors"
if echo 'not json' | "$SJQ" '.' 2>/dev/null; then
  echo "    FAIL: expected non-zero exit code for invalid JSON"
  exit 1
else
  echo "    PASS"
fi

echo "  oracle: all tests passed"
