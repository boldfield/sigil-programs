# sjq: fix test_eval `jvalues_equal` (missing JObject + JBool arms)

Task spec for the sigil-programs board. **Kind:** implement · **Track:** build ·
**Model:** haiku · **Files:** `sjq/test_eval.sigil` only.

This is the fix that unblocks a red `main`: `sjq/test_eval` fails, which fails
`make test-sjq` → `make test`, so **every** branch (including `surl: -b`) is
blocked until it lands.

## Spec

FIRST, before writing any code: fetch and read the Sigil language and stdlib
docs (also listed in the repo CLAUDE.md) — <https://sigillang.ai/language.raw.md>
(syntax, effect rows, pattern matching, modules) and
<https://sigillang.ai/stdlib.raw.md> (exact stdlib types and function
signatures). Sigil is not in your training data; do not guess syntax or stdlib
APIs.

Root cause: the test comparator `jvalues_equal` in `sjq/test_eval.sigil` has
match arms for `JNull`, `JInt`, `JString`, and `JArray`, but **no arm for
`JObject` and no arm for `JBool`** — both fall through to the catch-all default
arm and compare as unequal. So two equal objects, or two equal booleans, are
always reported unequal. The `select`-keep
tests fail as a result: `test_select_truthy_field` compares `{foo: JInt(42)}`
against itself, and `test_select_true_field` compares `{foo: JBool(true)}` — both
require object (and, for the latter, bool) equality. The `false`/`null` select
tests pass only because they expect the empty stream (`Nil`), which never reaches
the object comparison.

This is a latent test-helper bug, not a `select` bug and not a production bug:
`sjq/test_eval.sigil` is byte-identical to when it last ran green, and
`sjq/eval.sigil` is correct. It was masked on the x86_64-linux CI runner until
the toolchain was bumped v1.3.0 → v1.4.0 (for surl's `Net` effect), which changed
codegen enough to expose it. **Do not modify `sjq/eval.sigil`.**

Fix (confined to `sjq/test_eval.sigil` only):

1. Give `jvalues_equal` a case for `JObject`. Two objects should compare equal
   by walking their key/value pairs in order — the same way the existing array
   case compares two `JArray` values via `jlist_equal`: equal when every key
   matches and every corresponding value is itself equal, and both objects end
   together. Positional comparison is sufficient; the tests construct both
   operands identically, so key reordering need not be handled.
2. Give `jvalues_equal` a case for `JBool`: two booleans are equal when they
   hold the same value.

Leave the existing default (catch-all) arm and all other cases unchanged.

## Acceptance

- `make test-sjq` is green and the `test_eval` entry exits 0.
- All four `test_select_*` cases pass (`truthy`, `true`, `false`, `null`), and
  every other existing test still passes.
- No changes outside `sjq/test_eval.sigil` (production `eval.sigil` unchanged).
- `make test` green (CI).

## Testing (required)

The existing `test_select_truthy_field` and `test_select_true_field` now pass and
lock this in. Optionally add a direct comparison test asserting that two equal
objects compare equal, two objects differing in one value compare unequal, and
two equal booleans compare equal while a true/false pair does not. Verify
`make test` passes before submitting.

## Validation

The fix has been reproduced and confirmed against the pinned **v1.4.0**
toolchain: adding the two cases takes `test_eval` from exit 1 (with
`test_select_truthy_field` and `test_select_true_field` failing) to exit 0, all
tests passing. `string_compare`, `JObject`, `JOCons`, `JONil`, and `JBool` are
already imported at the top of the file, so no import changes are needed.
