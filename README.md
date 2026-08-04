# OpenStrap protocol

[![test](https://github.com/OpenStrap/protocol/actions/workflows/test.yml/badge.svg)](https://github.com/OpenStrap/protocol/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![stars](https://img.shields.io/github/stars/OpenStrap/protocol?style=flat&color=e2825f)](https://github.com/OpenStrap/protocol/stargazers)
[![Donate](https://img.shields.io/badge/donate-BTC%20%2F%20ETH-f7931a)](https://github.com/OpenStrap/edge/blob/main/DONATE.md)

Pure Dart, zero runtime deps. You hand it an already-unwrapped chunk of bytes from the
band, it hands you back a record with named fields, or a decoded command/event. That's
the whole job.

This isn't backend-side anymore. The app ([edge](https://github.com/OpenStrap/edge))
depends on this package directly and calls it on-device. There's no cloud, no upload, no
server that ever sees your raw bytes.

> Not affiliated with WHOOP. This is for reading your own band's data.

## What's actually in here

- `records.dart` contains the record decoders (`R24`, `parseR24`, and the firmware-aware
  fallback chain for older/short frames; see below).
- `live.dart` contains the live/high-rate stuff: R10, the 0x28 compact-HR stream, the
  0x33 IMU stream, RR-interval extraction.
- `framing.dart` contains the actual byte-level framing: `0xAA` start-of-frame, CRC8
  length check, CRC32 payload check, the length-based reassembler. This lives HERE, not
  upstream. A previous version of this README claimed there was no framing code in this
  package at all, which stopped being true a while ago.
- `crc.dart` contains crc8/crc32.
- `commands.dart` / `control.dart` contain command builders (SET_CLOCK, alarms, sync
  commands, etc.) and the control-plane decoders (HELLO, events, command responses,
  metadata/sync markers).
- `constants.dart` contains the GATT UUIDs, opcode tables, event IDs.

## The one record that matters most

`parseR24` decodes the 1 Hz historical record, the bulk of what comes off the band
during a sync, one of these per second of wear. Give it the inner payload and you get
back an `R24`, or `null` if it doesn't decode:

```dart
class R24 {
  final int histVersion;     // layout version byte @ inner[1]
  final int tsEpoch;         // unix seconds @ inner[7:11]
  final int tsSubsec;        // sub-seconds @ inner[11:13]
  final int counter;         // record counter @ inner[3:7]
  final int hr;               // heart rate bpm @ inner[17]; 0 means off-wrist, not bradycardia
  final int rrCount;          // 0-4 beat-to-beat intervals this second
  final List<int> rrIntervalsMs;
  final int ppgGreen;         // raw green-LED PPG ADC @ inner[29]
  final int ppgRedIr;         // raw red/IR-LED PPG ADC @ inner[31]
  final List<double> accelG;  // 3x float32 gravity vector @ inner[36:48]
  final int skinContact;      // contact QUALITY @ inner[51]; NOT wear/on-wrist state
  final int spo2RedRaw;       // raw red-channel ADC @ inner[64]
  final int spo2IrRaw;        // raw IR-channel ADC @ inner[66]
  final int skinTempRaw;      // raw skin-temp ADC @ inner[68]
  final int ambientRaw;       // raw ambient-light ADC @ inner[70]
  // ...
}
```

```dart
import 'package:openstrap_protocol/openstrap_protocol.dart';

final sample = parseR24(inner);
if (sample != null) {
  print('${sample.hr} bpm at ${DateTime.fromMillisecondsSinceEpoch(sample.tsEpoch * 1000)}');
}
```

All the SpO2/skin-temp/ambient fields are **raw relative ADC counts**, not calibrated
units. There's no absolute % or °C conversion here, and there shouldn't be one anywhere
downstream either. `skinContact` is a contact-quality signal, not a wear-state flag. Do
not use it to decide if the band is on the wrist.

Historical records don't all ship the same layout, and finding that out cost more time
than it should have. `parseR24` decodes v24/v12 verbatim; `FirmwareAwareR24Decoder`
(chain-of-responsibility) is the one to actually reach for on real devices. It tries the
validated 89-byte layout first, then falls back to a 72-byte-floor layout (the true
minimum every field it reads actually needs) for older firmware sending shorter frames,
remembering per-record-version which strategy worked. Other versions (v7/v9/v18/unknown)
route through the v24 field map at a per-version HR offset, gated by a
physiological-plausibility check (HR 25-230bpm AND accel magnitude² 0.25-3.24), because
without that gate, an implausible unknown-version record gets decoded as if it were real,
and you don't find out until your heart rate graph has a 400 bpm spike in it.

### WHOOP 4 historical v25

`v24` and `v25` are values of the historical-record layout byte (`inner[1]`) inside a
`0x2f` packet. They are **not firmware versions** and must not be used to infer the
installed firmware.

The current v25 decoder has a deliberately narrow contract:

- Real published WHOOP 4 frames establish an 84-byte framed record (76-byte inner
  payload), Unix timestamp at framed offset 11, and three-axis gravity at offsets
  73/75/77 as signed little-endian integers scaled by 16384.[^v25-layout]
- The corresponding inner offsets are 7 for the timestamp and 69/71/73 for gravity.
  `parseR24` exposes those fields only after a gravity-magnitude plausibility check.
- V25 has no verified per-second HR or RR field. The decoder therefore returns `hr: 0`
  and no RR intervals; consumers must not let that placeholder overwrite a valid v24
  sample at the same timestamp.
- Independent reverse engineering labels framed bytes 23–72 as an optical PPG region,
  but the exact sample start and sample count remain unpinned.[^v25-map][^v25-analysis]
  A proposed HR extraction was withdrawn after its apparent 60 bpm result was shown to
  be a record-boundary autocorrelation artifact.[^v25-guard]

A maintainer hardware capture observed v25 as periodic short runs alongside separate
normal one-second records at the same timestamps.[^v25-maintainer-capture] That establishes
v25 as supplemental for that capture, not a replacement for v24; it is not evidence that
every firmware or hardware revision behaves identically. The capture also showed temporal
association with realtime-HR operation, but association is not causation.

The exact v25 emission trigger and optical purpose remain **unknown**. In particular,
there is no evidence sufficient to label it as SpO2, calibration, signal-quality, or HR
input. Preserve the raw bytes and decode only timestamp and gravity until independently
validated captures pin more fields.

[^v25-layout]: [NOOP real WHOOP 4 v25 frame tests, commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop4HistoricalV25Tests.swift)
[^v25-map]: [NOOP version-gated v25 field map, commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift#L316-L345)
[^v25-analysis]: [NOOP v25 waveform analysis harness, commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Tools/linux-capture/analyze_v25_waveform.py)
[^v25-guard]: [NOOP executable false-HR guard, commit `3b86b6e`](https://github.com/ryanbr/noop/blob/3b86b6ef9e75292855202cc3931d44f77b9ac6f3/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop4HistoricalV25PpgTests.swift)
[^v25-maintainer-capture]: OpenStrap maintainer hardware observation, analyzed
  2026-08-04. The device-specific raw capture is intentionally not tracked; this
  provenance is therefore not independently accessible from the repository.

## What's actually verified vs. a plausible read

The header and heart rate are solid. `hr` at `inner[17]` has been checked against a live
stream on a real worn band, not just inferred from the byte layout looking right.

The PPG/accel/optical fields further into the record are a real, working decode too (the
whole map is checked against a frozen TypeScript oracle using
`decode_parity_cases.json`, 2934 real captured cases, all passing). But "decodes
correctly" and "means something diagnostic" are two different claims, and it's easy to
blur them if you're not careful. SpO2/skin-temp/ambient are raw ADC counts with no
calibration curve behind them. They are relative only, always, no exceptions.

## How a sync with the band actually goes

This package doesn't own a Bluetooth connection; it just builds/decodes the bytes. If
you're integrating it, or just curious what the app built around it actually does, the
conversation with the band looks like this.

Connect, bond, bump the MTU, subscribe to the notify characteristics. Then send
`cmdSetClock`. The band ships with its real-time clock unset, and skip this step and
every record you pull off it gets a garbage timestamp. Nothing tells you this up front;
you just find out later when your sleep data says you went to bed in 1970. Then fire
`initPackets` (five packets), which tells the band to start draining its history.

History comes off in batches. After each one, the band sends a marker carrying an 8-byte
token. Echo it back exactly with `buildHistoryResultOk`, using a write that waits for
acknowledgement, not fire-and-forget. Get the bytes wrong, or don't wait for the ack, and
the band just re-sends the same batch forever, since as far as it's concerned nothing was
ever confirmed. Whatever's consuming these decoded records needs to actually commit them
to storage before that acknowledgement goes out, not after. A crash mid-sync shouldn't
be able to lose data or tell the band to trim flash it never actually saved.

A couple of other things worth knowing if you're writing a client: live high-rate streams
(R10/0x33) and the historical 1 Hz records use separate sequence-number ranges, so acks
across the two never collide. And `dangerousCmds` in `constants.dart` (flash erase,
reboot, firmware push) exist for a reason. Gate them behind an explicit user action;
never auto-send. You really don't want to brick one of these.

The actual client implementation of all this contains the real Bluetooth connection,
the retry logic, and everything else. It lives in
[edge](https://github.com/OpenStrap/edge)'s `ble_engine.dart`, if you want to see it wired
up end to end.

## Build it

Pure Dart, no Flutter dependency:

```bash
dart pub get
dart test          # 71 tests, incl. the 2934-case TS-parity suite
```

Run tests from the repo root. The parity fixture (`decode_parity_cases.json`) is resolved
relative to it.

## Adding or fixing a decoder

If you've figured out a field or want to add a new record type: read multi-byte values
little-endian, return `null` (never throw) on malformed/short input, and label anything
you're not 100% sure of as empirical, not verified. A confident wrong label is worse than
an honest "not sure." If you're touching `records.dart`'s multi-version decode chain,
check `FirmwareAwareR24Decoder` first. Chances are your case fits the existing fallback
shape rather than needing a new one.

Cross-checking against `_external/noop/`  `bWanShiTong/reverse-engineering-whoop-post/`  for facts/techniques is fine; copying its code is not.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for which repo a change belongs in, how to run
the tests, and the rules that keep this package honest. Security issues go through
[SECURITY.md](SECURITY.md), not a public issue.

## Support the work

No subscription, no paywall, no company behind this. If OpenStrap gave your band a second
life, a small tip genuinely helps:

- **BTC:** `bc1qvtcch38dcwp967ar764uu6eetw7tf907844wfq`
- **EVM** (Ethereum · Base · Arbitrum · Optimism · Polygon):
  `0x8310C89393366b7eBCD47ABa82e1dfB5ECeFFbD9`

[What donations actually pay for →](https://github.com/OpenStrap/edge/blob/main/DONATE.md)

Nothing is gated behind paying, and nothing ever will be. Protocol findings and bug
reports are worth more than money, though.

---

Not affiliated with, endorsed by, or connected to WHOOP. "WHOOP" is their trademark, used
only to say which device this talks to.
