# surl: every HTTPS request fails with an opaque "TLS error"; `insecure` is a dead field

Task spec for the sigil-programs board. **Kind:** implement · **Track:** build ·
**Model:** sonnet · **Files:** `surl/fetch.sigil`, `surl/args.sigil`,
`surl/fixture.py`, `surl/run-oracle.sh`.

This is an **investigation task first and a fix task second**. The cause
of the TLS failure is not yet known, and the deliverable includes finding
out — and determining whether the fix belongs in this repo at all or
upstream in the Sigil stdlib.

## Spec

FIRST, before writing any code: fetch and read the Sigil language and stdlib
docs (also listed in the repo CLAUDE.md) — <https://sigillang.ai/language.raw.md>
and <https://sigillang.ai/stdlib.raw.md>. Pay particular attention to
`std.net`: `connect` takes a `tls: Bool`, and `NetError` includes a
`TlsError(String)` variant carrying a message. Sigil is not in your
training data; do not guess syntax or stdlib APIs.

Every HTTPS request fails. `surl https://example.com` exits 1 having
printed exactly `TLS error`, while `curl https://example.com` returns 200
from the same shell. Reproduced against three unrelated hosts, on both
arm64 darwin (native) and x86_64 Linux, under both the v1.4.0 and v1.4.2
toolchains, with a system CA bundle present and with `SSL_CERT_FILE`
pointing at it explicitly. It is not host-specific, platform-specific,
toolchain-specific, or an environment artifact.

HTTPS is fully wired in `surl/fetch.sigil` — the scheme is inspected, a
TLS flag is passed to `connect`, and `TlsError` is matched — but **no test
has ever made an HTTPS request**. The entire oracle runs against a
plaintext localhost fixture, so this surface has never been exercised.

**Start by surfacing the diagnostic, because right now it is being thrown
away.** The stdlib's `TlsError` carries a `String` payload explaining the
failure, but surl collapses every TLS failure to the same bare `TLS error`
string, so there is currently no way to tell certificate-verification
failure from a handshake or protocol-negotiation problem, or from a path
the stdlib does not implement. Propagate the payload to the user's error
output first; that alone is likely to identify the cause and is worth
having regardless of what the cause turns out to be. Apply the same
scrutiny to the other `NetError` variants while in `fetch.sigil` — if any
others discard a message payload the same way, they have the same defect.

Once the message is visible, determine the cause and **report it**. The
outcome decides ownership, and either answer is an acceptable result for
this task:

- If surl is misusing the API — wrong port, wrong flag, missing SNI or
  host information, an error path handled incorrectly — fix it here and
  add the coverage below.
- If the stdlib's TLS support is incomplete or broken, do **not** attempt
  to work around it in surl. Write up the finding with the reproduction
  and hand it to the sigil board; that repo owns `std.net`. Say so
  explicitly in the task result so the follow-up is not lost.

Separately, resolve the dead `insecure` field. `Config` in
`surl/args.sigil` declares `insecure: Bool`, `parse_args` hardcodes it to
`false`, and no flag anywhere parses it — it is inert configuration that
implies a capability surl does not have. Either implement the `-k` /
`--insecure` flag properly, or delete the field. Which is appropriate
depends on whether `std.net` actually exposes any control over
certificate verification: check the stdlib docs, and if no such control
exists, deleting the field is the honest outcome — do not add a flag that
silently does nothing. Note that this question is entangled with the TLS
investigation above, so settle that first.

## A design question to settle before writing the HTTPS test

The oracle currently runs entirely against a local fixture and needs no
network. Adding an HTTPS case against a public host would make CI depend
on the public internet and on a third party's certificate remaining
valid — a real source of unrelated future failures.

The alternative is terminating TLS locally in `fixture.py` with a
self-signed certificate, which keeps the suite hermetic but then requires
surl to skip verification to talk to it — which is exactly what `-k`
would be for, and which may not be expressible if the stdlib exposes no
such control.

Decide deliberately and record the reasoning. If neither option is
workable yet, say so and note what would unblock it rather than adding a
flaky network-dependent case by default.

## Acceptance

- A TLS failure reports the underlying reason from the stdlib rather than
  a bare `TLS error`, so the failure mode is identifiable from output
  alone.
- The cause of the HTTPS failure is identified and written up in the task
  result, including whether it belongs to surl or to `std.net`.
- If the cause is in surl: `surl https://<host>` returns the same body as
  `curl https://<host>`, and an oracle case covers HTTPS per the decision
  above.
- If the cause is upstream: the finding is handed to the sigil board with
  a reproduction, and surl's error output still names the real reason.
- `insecure` is either implemented as a working `-k` flag or removed from
  `Config` — no inert field remains.
- `make test` green.

## Testing (required)

Whatever the outcome, add a regression test that fails if TLS errors
become opaque again — the swallowed diagnostic is the reason this took a
manual investigation to characterise, and it is worth locking down
independently of the underlying bug.

If the HTTPS path is fixed in this repo, cover it in the oracle per the
design decision above. If `-k` is implemented, cover it; if the field is
removed, confirm no flag parsing or `Config` construction still refers to
it.

Verify `make test` passes before submitting.

## Depends on

`surl-http11-keepalive-hang.md`. Both touch `surl/fetch.sigil`, and the
keep-alive fix changes how responses are read — which an HTTPS request
will also go through. Landing that first avoids conflicting edits and
avoids diagnosing TLS through a second, unrelated hang.
