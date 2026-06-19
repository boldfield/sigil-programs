# sjq — a jq-style JSON filter in Sigil

Status: draft (feature_spec for the sigil-programs board)
Date: 2026-06-18
Target: `sigil-programs` repo, `sjq/` directory; built against the
Sigil **v1.2.0** release toolchain.

## Problem / motivation

A small `jq`-style JSON filter, written in pure Sigil. It dogfoods two
things at once: multi-file Sigil programs (shipped in v1.2.0) and the
JSON stdlib with float support (`JFloat`, v1.2.0). It needs no
capability Sigil lacks — JSON parse/render, stdin (`IO.read_line`),
argv (`Env.args`), and file read (`Fs.read_file`) all exist.

## Goals (MVP)

A filter language over `JValue` with jq's **value-stream** semantics —
a filter maps one input value to a *stream* (list) of output values:

- `.` — identity
- `.foo`, `.foo.bar` — field access (chained)
- `.[N]` — array index
- `.[]` — iterate (explodes an array/object into the stream)
- `a | b` — pipe (compose: run `b` on each output of `a`)
- `length` — length of an array/object/string (jq semantics)
- `keys` — sorted keys of an object (or indices of an array) as an array
- `select(f)` — emit the input only if the sub-filter `f` is truthy
  (jq truthiness: everything except `false`/`null`)

CLI: `sjq '<filter>' [file]` — filter is the first argument; input is
the file if given, else stdin. Input is one JSON value; each value in
the result stream is rendered (via `json_render`) on its own line, jq-
style.

## Non-goals

- The rest of jq's language: user-defined functions, `reduce`,
  arithmetic, string interpolation, object/array construction, `map`,
  path expressions, modules, `--slurp`/`--raw`. The MVP is the eight
  forms above (five navigation forms + `length`/`keys`/`select`); more
  can follow as later tasks.
- YAML (`yq`) — no YAML parser exists in Sigil.
- Streaming / very large inputs (reads the whole input, parses one
  value).

## Architecture (multi-file Sigil program)

**Layout note — load-bearing.** Sigil resolves imports root-anchored to
the *entry file's directory*. So every module a program uses must live
under that directory. Therefore **all files live flat under `sjq/`**,
and each entry (`main.sigil` and the per-module test drivers) imports
its siblings directly (`import lexer` → `sjq/lexer.sigil`).

Modules:

- `sjq/ast.sigil` — the shared types: the token type (lexer↔parser) and
  the filter AST (parser→evaluator). No `main`.
- `sjq/lexer.sigil` — tokenize a filter string into tokens. No `main`.
- `sjq/parser.sigil` — tokens → filter AST. No `main`.
- `sjq/eval.sigil` — evaluate a filter AST against a `JValue`, returning
  the value stream (`List[JValue]`). No `main`.
- `sjq/main.sigil` — the CLI entry: read argv + input, `json_parse`,
  `lex → parse → eval`, `json_render` each result.

**Value-stream semantics** (the core idea): `eval(filter, input) ->
List[JValue]`. Identity → `[input]`. `.foo` → the field's value (or an
error if absent / not an object). `.[]` → the array's elements (explode)
. `.[N]` → the single indexed element. `a | b` → flat-map: run `b` on
every output of `a` and concatenate.

## Testability + parallel authorship

To let the engine modules be authored **in parallel** (the payoff
multi-file imports unlocks), each module ships with a tiny **test
driver** entry alongside it — `sjq/test_lexer.sigil`,
`sjq/test_parser.sigil`, `sjq/test_eval.sigil` — that imports just that
module, exercises it, and prints a fixed result. Because each driver is
a self-contained entry under `sjq/`, the module is independently
compilable and runnable (green) before `main` exists. CI compiles and
runs every entry (`main.sigil` + `test_*.sigil`).

## Build / CI (repo harness, bootstrapped before tasks)

The `sigil-programs` repo carries a CI workflow that:
1. Downloads the Sigil **v1.2.0** release tarball for the runner's
   platform, extracts it, puts `bin/sigil` on `PATH` (its bundled
   `lib/libsigil_runtime.a` links automatically).
2. Compiles every entry under `sjq/` (`main.sigil` + each
   `test_*.sigil`) and runs it.
3. Runs the oracle suite: a set of `(filter, input)` cases compiled
   through `sjq` and diffed against system `jq` (1.7.x) output.

This harness + the repo skeleton + this design doc are **bootstrapped
directly** (infrastructure, not Sigil code); the Sigil source is the
board's work.

## Acceptance criteria

1. All eight MVP forms — `.`, `.foo`/`.foo.bar`, `.[N]`, `.[]`,
   `a | b`, `length`, `keys`, `select(f)` — produce output matching
   `jq` on a representative case set.
2. Value-stream semantics hold: `.[]` explodes; `a | b` composes over
   the stream; `select` filters it.
3. Reads from both stdin and a file argument.
4. Malformed JSON and malformed filters produce a clear error and a
   non-zero exit (not a crash).
5. **CI is green (mandatory — repo policy).** Every program in
   `sigil-programs` must carry CI testing as an acceptance criterion:
   CI downloads the pinned Sigil **v1.2.0** release toolchain, compiles
   and runs every `sjq/` entry, and the oracle suite matches `jq`. A
   task is not done until its CI is green.

## Decomposition (board tasks; one increment each, green at every step)

Each task is one logical increment that compiles and runs (its module's
test driver, plus all earlier entries). Within a module, increments
chain (same file); the three module chains run **concurrently** after
`sjq-ast`.

**Foundation**

1. **`sjq-ast`** — `sjq/ast.sigil`: define **all** token kinds
   (incl. `[` `]` `(` `)` `|`, int, identifier, dot) and **all**
   filter-AST variants (Identity, Field, Index, Iterate, Pipe, Length,
   Keys, Select) up front; `sjq/test_ast.sigil` builds and prints a
   sample AST. Declaring every variant now is what lets the later
   chains use exhaustive stubs and run in parallel. *(no deps)*

**Lexer chain** (`lexer.sigil` + `test_lexer.sigil`)

2. **`sjq-lexer-core`** — tokenize `.` and bare identifiers (field
   names and builtin names share the identifier token). *(deps:
   sjq-ast)*
3. **`sjq-lexer-rest`** — add `[`, `]`, `(`, `)`, integer, and `|`
   tokens. *(deps: sjq-lexer-core)*

**Parser chain** (`parser.sigil` + `test_parser.sigil`) — drivers build
tokens directly from `ast`, so no dependency on the lexer

4. **`sjq-parser-core`** — parse identity `.` and chained field access
   `.foo`/`.foo.bar` into AST. *(deps: sjq-ast)*
5. **`sjq-parser-index-iter`** — parse `.[N]` and `.[]`. *(deps:
   sjq-parser-core)*
6. **`sjq-parser-pipe`** — parse the `a | b` combinator. *(deps:
   sjq-parser-index-iter)*
7. **`sjq-parser-builtins`** — parse the bare-identifier builtins
   `length` / `keys` and the `select( <filter> )` call. *(deps:
   sjq-parser-pipe)*

**Eval chain** (`eval.sigil` + `test_eval.sigil`) — drivers build a
`JValue` + AST directly, no dependency on lexer/parser

8. **`sjq-eval-core`** — `eval(filter, input) -> List[JValue]` with an
   **exhaustive** match over all AST variants: identity + field fully
   implemented; Index / Iterate / Pipe / Length / Keys / Select arms
   raise "not yet supported" (filled in by the next tasks). *(deps:
   sjq-ast)*
9. **`sjq-eval-index-iter`** — implement the Index (`.[N]`) and Iterate
   (`.[]`, explode) arms. *(deps: sjq-eval-core)*
10. **`sjq-eval-pipe`** — implement the Pipe arm (flat-map over the
    stream). *(deps: sjq-eval-index-iter)*
11. **`sjq-eval-length-keys`** — implement the Length and Keys arms.
    *(deps: sjq-eval-pipe)*
12. **`sjq-eval-select`** — implement the Select arm (recursively eval
    the sub-filter; emit input on jq-truthiness). *(deps:
    sjq-eval-length-keys)*

**CLI + oracle**

13. **`sjq-main-io`** — `sjq/main.sigil`: argv (filter + optional file),
    read stdin/file, `json_parse`, `json_render`; identity (`.`) only
    for now (other filters error). Stdlib-only, no engine imports —
    runs in parallel with the engine chains. *(no deps)*
14. **`sjq-main-wire`** — replace the passthrough: wire
    `lex → parse → eval` and render each stream value. *(deps:
    sjq-main-io, sjq-lexer-rest, sjq-parser-builtins, sjq-eval-select)*
15. **`sjq-oracle`** — the oracle case suite (`(filter, input)` pairs
    for all eight forms diffed against `jq`) wired into the CI test
    runner. *(deps: sjq-main-wire)*

**Parallelism:** after `sjq-ast`, four independent fronts open at once —
the lexer chain (2 tasks), parser chain (4), eval chain (5), and
`sjq-main-io` — converging only at `sjq-main-wire`.
