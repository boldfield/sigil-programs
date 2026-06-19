# CLAUDE.md — sigil-programs

Programs written in the **Sigil** language, built against the Sigil
**v1.2.0** release toolchain.

## Before writing or reviewing any code — read the Sigil docs

Sigil is not in your training data. **Fetch and read these first:**

- Language: <https://sigillang.ai/language.raw.md> — syntax, types,
  effect rows, pattern matching, the module system.
- Stdlib API: <https://sigillang.ai/stdlib.raw.md> — the exact public
  types and function signatures (e.g. `json_parse`, `JValue`).

Don't guess Sigil syntax or stdlib signatures — the docs are the source
of truth. If the build complains about something the docs cover, re-read
the relevant section rather than guessing.

## Build / test

`sigil` is on PATH in CI (the pinned v1.2.0 release; locally pass
`make SIGIL=/path/to/bin/sigil`). Use the Makefile:

- `make <program>` / `make test-<program>` — build / test one program.
- `make` / `make test` — every program. **CI runs `make test`.**

Every program must keep CI green (compiles + runs every entry + oracle).
