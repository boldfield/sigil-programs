# surl — a curl-style HTTP client in Sigil

Built against Sigil **v1.4.0** (the `Net` effect + `std.net`/`url`/`http`).
Lives in `surl/`. The stdlib does the heavy lifting; surl is the CLI glue.

## CLI

```
surl [-X METHOD] [-H 'K: V']… [-d DATA] [-o FILE] [-I] [-L] <url>
```

- `<url>` — `http://` or `https://`.
- `-X METHOD` — request method (default GET; POST implied with `-d`).
- `-H 'K: V'` — add a request header (repeatable).
- `-d DATA` — request body.
- `-o FILE` — write the response body to FILE instead of stdout.
- `-I` — print the status line + response headers instead of the body.
- `-L` — follow `3xx` redirects (bounded).

## Pipeline

```
parse_args(argv) -> Config
  → std.url.parse_url(config.url) -> Url
  → std.http build Request (method, headers, body from Config)
  → std.net.connect(host, port, tls = scheme == "https")
  → send(std.http.serialize_request) → recv_all → std.http.parse_response
  → print body  (-I: headers · -o: write to file · -L: follow Location)
```

Each step is a thin call into `std.url`/`std.http`/`std.net`. HTTPS is the
same pipeline with `tls = true`; the TLS transport itself is already
gated-tested at the runtime layer (the `Net` effect's TLS e2e), so surl's
https path needs no separate gated test — it shares the plaintext code.

## Testing — oracle vs `curl`

`surl/run-oracle.sh` stands up a **local HTTP fixture** (e.g.
`python3 -m http.server`) and compares `surl` against system `curl` on the
same `http://127.0.0.1:PORT/...` URL: GET body, `-I` headers, `-o` file
contents, and a redirect fixture for `-L`. Plaintext loopback only (no
public internet — flaky / sandbox-blocked). Wired into CI via the existing
`make test` → `run-oracle.sh` hook. (A real-`https` check is a separate,
non-gating smoke.)

CI note: `make test` also runs `surl/main.sigil` as a bare entry (no args),
so surl with no URL prints usage and exits 0; the oracle exercises real
behavior with args.

## Decomposition (single-unit haiku tasks; escalation is the safety net)

1. **`surl-args`** — `surl/args.sigil`: a `Config` record (all flags) +
   `parse_args(argv) -> Result[Config, String]`, plus `surl/test_args.sigil`.
2. **`surl-fetch-get`** — `surl/main.sigil`: the GET pipeline + print body
   (no-url → usage, exit 0); `surl/run-oracle.sh` with the local fixture +
   GET-body comparison vs `curl`, wired into CI.
3. **`surl-head`** — `-I` (status + headers) + oracle case vs `curl -I`.
4. **`surl-output-file`** — `-o FILE` via `std.fs` + oracle case.
5. **`surl-redirect`** — `-L` follows `3xx` via `Location` (bounded) +
   redirect-fixture oracle case.

`main.sigil` + `run-oracle.sh` are touched by tasks 2–5 (a serial chain);
`args.sigil` is task 1. `Config` declares all flag fields up front; tasks
2–5 consume them incrementally (each green).
