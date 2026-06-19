#!/bin/bash
set -e

SJQ="./bin/main"
JQ="jq"

# Helper to compare sjq and jq output
compare_outputs() {
  local name=$1
  local filter=$2
  local input=$3

  echo "  test: $name"

  # Run sjq
  sjq_out=$(echo "$input" | "$SJQ" "$filter" 2>&1)
  sjq_exit=$?

  # Run jq
  jq_out=$(echo "$input" | $JQ "$filter" 2>&1)
  jq_exit=$?

  # Compare exit codes
  if [ $sjq_exit -ne $jq_exit ]; then
    echo "    FAIL: exit code mismatch (sjq: $sjq_exit, jq: $jq_exit)"
    echo "    sjq output: $sjq_out"
    echo "    jq output: $jq_out"
    exit 1
  fi

  # Normalize both outputs to compact format for comparison
  sjq_norm=$(echo "$sjq_out" | jq -c '.' 2>/dev/null || echo "$sjq_out")
  jq_norm=$(echo "$jq_out" | jq -c '.' 2>/dev/null || echo "$jq_out")

  # Compare output
  if [ "$sjq_norm" != "$jq_norm" ]; then
    echo "    FAIL: output mismatch"
    echo "    filter: $filter"
    echo "    input: $input"
    echo "    sjq output:"
    echo "$sjq_out"
    echo "    jq output:"
    echo "$jq_out"
    exit 1
  fi

  echo "    PASS"
}

echo "Oracle suite: sjq vs jq"

# MVP Form 1: Identity (.)
compare_outputs "identity with simple object" "." '{"key":"value"}'
compare_outputs "identity with array" "." '[1,2,3]'
compare_outputs "identity with null" "." 'null'
compare_outputs "identity with number" "." '42'
compare_outputs "identity with string" "." '"hello"'
compare_outputs "identity with boolean" "." 'true'

# MVP Form 2: Field (.foo)
compare_outputs "field access existing" ".foo" '{"foo":"bar"}'
compare_outputs "field access missing" ".missing" '{"foo":"bar"}'
compare_outputs "field access from null" ".foo" 'null'
compare_outputs "field access nested" ".outer" '{"outer":{"inner":"value"}}'

# MVP Form 3: Index ([n])
compare_outputs "array index 0" ".[0]" '[10,20,30]'
compare_outputs "array index 1" ".[1]" '[10,20,30]'
compare_outputs "array index out of range" ".[5]" '[10,20]'
compare_outputs "array index on null" ".[0]" 'null'

# MVP Form 4: Iterate (.[], .[])
compare_outputs "iterate array" ".[]" '[1,2,3]'
compare_outputs "iterate object values" ".[]" '{"a":1,"b":2}'
compare_outputs "iterate empty array" ".[]" '[]'
compare_outputs "iterate empty object" ".[]" '{}'

# MVP Form 5: Pipe (|)
compare_outputs "pipe identity then field" ". | .foo" '{"foo":"bar"}'
compare_outputs "pipe iterate then field" ".[] | .name" '[{"name":"alice"},{"name":"bob"}]'
compare_outputs "pipe field then iterate" '.items | .[]' '{"items":[1,2,3]}'

# MVP Form 6: Length
compare_outputs "length of array" "length" '[1,2,3,4,5]'
compare_outputs "length of object" "length" '{"a":1,"b":2}'
compare_outputs "length of string" "length" '"hello"'
compare_outputs "length of null" "length" 'null'
compare_outputs "length of empty array" "length" '[]'

# MVP Form 7: Keys
compare_outputs "keys of object" "keys" '{"z":1,"a":2,"m":3}'
compare_outputs "keys of array" "keys" '[10,20,30]'
compare_outputs "keys of empty object" "keys" '{}'
compare_outputs "keys of empty array" "keys" '[]'

# MVP Form 8: Select
compare_outputs "select truthy number" ".[] | select(.)" '[1,2,3,null,false]'
compare_outputs "select truthy object" ".[] | select(.active)" '[{"active":true},{"active":false}]'
compare_outputs "select with pipe" ".[] | select(.x)" '[{"x":1},{"x":2},{"y":3}]'

# Error cases: malformed JSON
echo "  test: malformed JSON input"
sjq_exit=0
echo 'not json' | "$SJQ" '.' >/dev/null 2>&1 || sjq_exit=$?
jq_exit=0
echo 'not json' | $JQ '.' >/dev/null 2>&1 || jq_exit=$?
if [ $sjq_exit -eq 0 ] || [ $jq_exit -eq 0 ]; then
  echo "    FAIL: malformed JSON should error"
  exit 1
fi
echo "    PASS"

echo "Oracle suite: all tests passed"
