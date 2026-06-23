# sigil-programs

Programs written in the [Sigil](https://github.com/boldfield/sigil)
language. This repo is **application code** — it consumes a released
Sigil toolchain; it is not the compiler (that lives in
[`boldfield/sigil`](https://github.com/boldfield/sigil)).

Each program lives in its own top-level directory and is built against a
pinned Sigil **release** — CI downloads the prebuilt `bin/sigil` from a
`v*` GitHub release of the compiler (no build-from-source).

## Policy: CI testing is mandatory

**Every program must carry CI testing as an acceptance criterion.** A
program is not "done" until its CI run is green: CI compiles and runs
every entry, and (where the program has a reference implementation)
diffs output against an oracle. See `.github/workflows/ci.yml`.

## Programs

- **`sjq/`** — a `jq`-style JSON filter. Multi-file Sigil program (lexer
  / parser / evaluator), oracled against system `jq`. Design:
  [`docs/sjq-design.md`](docs/sjq-design.md).
- **`surl/`** — a `curl`-style HTTP client. Uses `std.net`/`url`/`http`
  (TCP + TLS), oracled against system `curl`. Built against Sigil
  v1.4.0.

## Build

The root `Makefile` has per-program targets (`sigil` must be on `PATH`,
or pass `SIGIL=/path/to/bin/sigil`):

```sh
make            # build every program → bin/<program>
make sjq        # build one program
make test       # build + run every entry and oracle (what CI runs)
make test-sjq   # test one program
make clean
```

Add a program by creating `<name>/main.sigil` and appending `<name>` to
`PROGRAMS` in the `Makefile`.
