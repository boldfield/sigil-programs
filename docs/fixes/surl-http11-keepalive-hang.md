# surl: hangs forever against any HTTP/1.1 keep-alive server

Task spec for the sigil-programs board. **Kind:** implement · **Track:** build ·
**Model:** sonnet · **Files:** `surl/fetch.sigil`, `surl/fixture.py`,
`surl/run-oracle.sh`.

This is the highest-severity open defect in surl: outside its own test
fixture, surl does not work. Nearly every production web server speaks
HTTP/1.1 with persistent connections, and against all of them surl
blocks forever instead of returning.

## Spec

FIRST, before writing any code: fetch and read the Sigil language and stdlib
docs (also listed in the repo CLAUDE.md) — <https://sigillang.ai/language.raw.md>
(syntax, effect rows, pattern matching, modules) and
<https://sigillang.ai/stdlib.raw.md> (exact stdlib types and function
signatures, in particular `std.net` and `std.http`). Sigil is not in your
training data; do not guess syntax or stdlib APIs.

Root cause: `surl/fetch.sigil` reads the response with `recv_all`, which
consumes until the peer closes the connection, and surl never sends a
`Connection: close` request header. So surl only terminates against a
server that hangs up after responding. An HTTP/1.1 server keeps the
connection open for reuse, `recv_all` never sees EOF, and surl hangs.

The bug is invisible to the current suite because `surl/fixture.py` does
not override `protocol_version`, and Python's `BaseHTTPRequestHandler`
therefore defaults to **HTTP/1.0** and closes after every response. All
sixteen oracle cases pass against a server that behaves unlike anything
surl will meet in production.

Reproduction — same binary, same localhost, identical response body, the
only difference being the server's advertised protocol version:

```
server speaks HTTP/1.0 -> curl: hello | surl: 'hello' exit=0
server speaks HTTP/1.1 -> curl: hello | surl: HANG (timed out)
```

The same hang occurs against any real host over plain HTTP, while `curl`
against that host returns 200 from the same shell, so this is surl's
behaviour and not an environment artifact.

Fix the read strategy: decide how many body bytes to consume from the
response's own framing rather than waiting for a close. When the response
carries a `Content-Length`, read exactly that many bytes and stop. When it
carries `Transfer-Encoding: chunked`, read chunks until the terminating
zero-length chunk. Only when neither framing is present is reading to
end-of-connection correct — that is the legitimate HTTP/1.0 case, and it
must keep working, since the existing fixture and oracle depend on it.

The response parser in `fetch.sigil` already understands both framings —
a comment there states as much. The defect is that the *read* completes
before parsing ever gets a chance to apply that knowledge. Reuse the
existing parsing rather than adding a second, parallel notion of body
length.

Two details that will otherwise bite:

- A `HEAD` response may advertise a non-zero `Content-Length` while
  sending no body at all. `fetch.sigil` already carries a note about
  this. Do not block waiting for bytes that will never arrive; the
  head-only path must complete on headers alone.
- Redirect following issues more than one request. Every hop needs the
  same termination logic, or `-L` will hang on the first HTTP/1.1 hop
  even after the single-request path is fixed.

Do **not** fix this by sending `Connection: close` and continuing to read
to EOF. It would make the symptom disappear, but it discards a connection
per request, leaves surl permanently unable to support persistent
connections, and leaves the underlying read still unable to honour the
framing the parser already reads. Fix the read.

Then close the test gap that hid this. Set `protocol_version` to
`HTTP/1.1` in `surl/fixture.py` so that **every** existing oracle case
exercises the persistent-connection path, which is what real servers do.
The existing assertions compare surl against curl rather than against
hardcoded protocol strings, so they should continue to hold — including
the `-I` status-line case, where both tools will simply report the new
version. If any case genuinely needs an HTTP/1.0 server, add a second
fixture endpoint or a second server rather than reverting the default.

Finally, guard the oracle against this class of regression: a hang must
fail the suite rather than stall it. Every surl invocation in
`run-oracle.sh` should be bounded by a timeout, so a future regression
surfaces as a failed case in a few seconds instead of an eight-hour CI
job that gets cancelled with no useful signal.

## Acceptance

- `surl <url>` completes against an HTTP/1.1 server that keeps the
  connection open, and its body matches curl byte-for-byte.
- `surl <url>` still completes against an HTTP/1.0 server that closes the
  connection, matching curl.
- A chunked response is read to completion and matches curl.
- `-I` returns on headers alone against an HTTP/1.1 server, even when the
  response advertises a non-zero `Content-Length`.
- `-L` follows redirects to completion against an HTTP/1.1 server, so
  every hop terminates, not only the last.
- `surl/fixture.py` serves HTTP/1.1, and all pre-existing oracle cases
  still pass against it.
- No surl invocation in `run-oracle.sh` can hang the suite; each is
  bounded and a hang is reported as a failure.
- `make test` green.

## Testing (required)

Add oracle coverage that would have caught this. At minimum: a case
against an HTTP/1.1 keep-alive server asserting surl returns and matches
curl, and a case against a chunked response. Keep a case that exercises
the HTTP/1.0 close-delimited path, since that is a legitimate response
shape and the fallback must not rot.

The decisive test is differential: run the same surl binary against two
servers differing only in `protocol_version` and assert both return. That
is the experiment that exposed the bug and it is cheap to keep.

Verify `make test` passes before submitting. Note that a regression here
manifests as a hang rather than a failure, so confirm the suite actually
completes rather than assuming a lack of failure output means success.

## Validation

Confirmed against the pinned **v1.4.2** toolchain on two platforms
(x86_64 Linux and arm64 darwin) and against v1.4.0, so this is neither
architecture- nor toolchain-specific. `curl` reaches both plain HTTP and
HTTPS from the same shell that surl hangs in, ruling out the environment.

## Out of scope

- HTTPS/TLS, which fails separately and for unrelated reasons. Tracked in
  `surl-tls-failure-and-dead-insecure-flag.md`.
