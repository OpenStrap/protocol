# Security Policy

## Reporting a vulnerability

Please **don't** open a public issue for a security problem.

Use GitHub's private reporting instead:
[**Report a vulnerability →**](https://github.com/OpenStrap/protocol/security/advisories/new)

That goes straight to the maintainer and stays private until there's a fix.

Rough expectations, set honestly — this is a one-maintainer project, not a
company with an on-call rota:

- Acknowledgement within about a week.
- An assessment, and a fix or a clear "won't fix and here's why", within 30 days
  for anything that puts user data at risk.
- Credit in the release notes if you want it.

## What this package actually is

This repo is a pure-Dart library with zero runtime dependencies: bytes in,
decoded records/frames/commands out. It doesn't run on its own, ship an app,
talk to a network, or store anything — no database, no telemetry, no
Firebase. It's a dependency of [edge](https://github.com/OpenStrap/edge),
which is where the app, its distribution model, and its data-handling
questions live.

## What's in scope

- A decoder that misparses bytes in a way that's exploitable, not just wrong
  (buffer overreads, crashes on malformed input, anything an attacker could
  use by controlling bytes the band or a proxy sends).
- Anything in this package's command builders that could be used to send a
  command to a band the caller didn't ask for.

## What's out of scope

- The band's own firmware. We don't ship it, can't patch it, and won't publish
  attacks against it.
- WHOOP's own apps and services. Please report those to WHOOP.
- App-level distribution and privacy questions (signing, sideloading, device
  storage access, telemetry, health-data upload) — those belong to
  [edge's SECURITY.md](https://github.com/OpenStrap/edge/blob/main/SECURITY.md)
  and [PRIVACY.md](https://github.com/OpenStrap/edge/blob/main/PRIVACY.md),
  not this repo.
- Metric accuracy. Wrong numbers are bugs — open a normal issue.
