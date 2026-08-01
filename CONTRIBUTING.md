# Contributing

This package is the byte layer: bytes off the band in, named records out. Keep
it that way — it has **zero runtime dependencies** and no I/O, and that's a
feature, not an accident. It runs on-device inside the app.

## What belongs here (and what doesn't)

| Your change | Repo |
|---|---|
| A record type, opcode, event, CRC/framing, GATT constant | **here** |
| A metric, or how a number is computed from records | [analytics](https://github.com/OpenStrap/analytics) |
| Bluetooth reliability, storage, sync, UI | [edge](https://github.com/OpenStrap/edge) |

Nothing in `lib/` may import `dart:io`, do network calls, or pull in a package.
If you need those, your change belongs in edge.

## Protocol findings are the most valuable contribution

A lot of the current event table is empirical guesswork by one person. If you've
worked out a field, an opcode, or an event we don't decode — or found one we
decode *wrongly* — that helps everyone with one of these bands.

Open an issue with:

- The raw frame bytes (hex), as many samples as you have.
- What you think the field is, and at what offset.
- **How you convinced yourself.** This is the important part. "HR at offset 17
  tracked my actual pulse across 40 minutes of wear, and offset 14 didn't" is a
  real answer. Correlating against a known ground truth beats pattern-matching.

Firmware versions differ. If a field only holds on one `histVersion`, say which
one — `parseR24` already routes per-version and that's usually where a new
finding lands.

## Ground rules

**Don't decode something you can't justify.** A wrong field is worse than a
missing one, because it silently poisons every metric downstream. If a value is
only *probably* right, gate it behind a plausibility check the way
`_physiologicallyPlausible` does (HR 25–230, |g|² 0.25–3.24) rather than
trusting it outright.

**Never guess a value to fill a gap.** If a record doesn't decode, return
`null`. The app archives undecodable records rather than discarding them, so a
`null` here is recoverable later; a fabricated value is not.

**Some opcodes are dangerous.** `dangerousCmds` exists for a reason — force-trim,
reboot, power-cycle, firmware load. Don't wire any of them into an automatic
path, and don't add new ones without a very clear justification in the PR.

## Tests

Run from the repo root:

```bash
dart pub get
dart analyze
dart test
```

Two things guard every change:

- **`decode_parity_cases.json`** — 2934 cases checked against the frozen
  TypeScript oracle in `ts/`. If you change a decoder and parity breaks, either
  your change is wrong or the oracle needs regenerating — work out which, and
  say so in the PR.
- **`dart_header.json`** — 550 hand-checked R24 header cases.

Both are tracked in-repo and run in CI. A third set replays
`whoop_hist.jsonl`, a real band capture kept *beside* the repo rather than in
it; those tests skip automatically when it's absent, which is what CI does.

New record types or opcodes should come with test cases from real frames.

## Pull requests

- Branch off `main`, one logical change per PR.
- Say how you verified it against real hardware.
- No `Co-Authored-By` trailers.

## Scope

Facts about a wire protocol, worked out by observing your own device, are fine.
Vendor source code, firmware, decompiled binaries, and material from other
reverse-engineering projects whose licences don't permit reuse are not — don't
paste them into code, comments, commits, or PR descriptions.
