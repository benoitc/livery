# Security Policy

## Supported Versions

Security fixes go into the latest minor release on the `main` branch.

| Version | Supported |
| ------- | --------- |
| 0.12.x  | yes       |
| < 0.12  | no        |

## What is a security issue

Report privately a problem that lets someone get past what the
configuration is meant to protect:

- running code on the server, or turning request data into atoms or
  terms (`binary_to_term/1`, `list_to_atom/1`);
- a request accepted without the authentication or authorization the
  configuration asks for: bearer tokens and JWT checks (signature,
  algorithm, expiry, audience, issuer), token introspection, session
  cookies, OIDC and JWKS key selection, client certificates
  (`verify => verify_peer`);
- one request's, session's or connection's data reaching another client;
- `livery_static` serving a file outside the directory it was given;
- CORS headers that grant an origin the configuration does not allow;
- the client sending credentials, cookies or tokens to a host they were
  not meant for;
- Livery weakening TLS below what the configuration asks for, such as
  skipping certificate verification.

These stay security issues even where a specification describes the
check.

## What is a bug

When the fix is to make Livery follow a specification it implements, or
to enforce a limit one of its options defines, it is a bug. That holds even
when the report calls it denial of service, resource exhaustion or a remote
crash. Report it as a public issue and cite the specification section or
the option; see
[Security issues and bugs](CONTRIBUTING.md#security-issues-and-bugs).
We don't publish advisories or request CVEs for these, and advisories filed
for them are closed as bugs with a link to the fix.

Livery does not parse the wire itself. HTTP/1.1, HTTP/2, HTTP/3, QUIC,
WebSocket and WebTransport framing live in separate libraries, each with
its own policy. Report a problem in one of them to that project; the list
is in [CONTRIBUTING.md](CONTRIBUTING.md#where-to-report).

Write the report in plain English, with a minimal reproduction, as described
in [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it).

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through GitHub's
[Private Vulnerability Reporting](https://github.com/benoitc/livery/security/advisories/new).

Do not open public issues or pull requests for security problems.

When reporting, include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Affected versions and platform details.
- Any suggested fix or mitigation.

You can expect an initial acknowledgement within 7 days. We will work with
you on a fix and coordinate disclosure once a patched release is available.
Credit will be given in the advisory unless you prefer to remain anonymous.
