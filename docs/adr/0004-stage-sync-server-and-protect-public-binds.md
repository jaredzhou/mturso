# Stage the sync server and protect public binds

## Status

accepted; amended 2026-11-13 to use an external TLS terminator

## Decision

The `SyncServer` facade supports two backends:

- `External` launches the pinned `tursodb --sync-server` process found through
  `TURSODB` or `PATH`. It remains loopback-only, uses plain HTTP, and has no
  built-in authentication. It is a development and test backend.
- `Native` launches the self-hosted protocol-compatible server. It is
  loopback-only by default and serves plain HTTP.

MoonBit does not currently provide a usable HTTPS server stack for this code
path. HTTPS is therefore outside the sync server: a deployment that needs a
public endpoint must put a TLS-terminating reverse proxy such as Caddy or nginx
in front of it. The proxy owns the certificate, SAN validation, public DNS/IP,
and TLS policy.

The native server protects its HTTP API with Pony middleware. A non-loopback
native bind additionally requires both:

- explicit `external_tls_proxy` mode, confirming that traffic is protected by
  a TLS-terminating proxy; and
- Bearer authentication.

When the proxy runs on the same host, binding the backend to loopback is
preferred. A non-loopback bind is intended only for a private network or
container network reachable by the trusted proxy, never direct public access.

Authentication supports a constant-time static Bearer token and a verifier
callback reserved for JWT/OIDC validation. All pipeline, cursor, and
`pull-updates` routes use the same middleware and return `401 Unauthorized`
without revealing whether the header was missing, malformed, or incorrect.

## Consequences

- Server startup rejects unsafe bind/authentication combinations before opening
  the database or listening.
- The external `tursodb` backend rejects built-in auth configuration because the
  process does not implement it; authentication for that backend must be
  enforced by an external proxy if ever exposed beyond loopback.
- A library-managed native child process can receive a static Bearer token
  through an explicit child environment variable. Verifier callbacks cannot be
  serialized across the process boundary and therefore use the in-process
  native server path.
- Bearer tokens, private keys, and complete sensitive headers must never be
  logged in errors, diagnostics, or stats.
- Reverse-proxy certificate and SAN correctness is a deployment responsibility;
  automatic certificate issuance is out of scope.
