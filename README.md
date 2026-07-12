# OpenStrap protocol

Pure Dart, zero runtime deps. You hand it an already-unwrapped chunk of bytes from the
band, it hands you back a record with named fields, or a decoded command/event. That's
the whole job.

This isn't backend-side anymore — the app ([edge](https://github.com/OpenStrap/edge))
depends on this package directly and calls it on-device. There's no cloud, no upload, no
server that ever sees your raw bytes.

> Not affiliated with WHOOP. This is for reading your own band's data.

## What's actually in here

- `records.dart` — the record decoders (`R24`, `parseR24`, and the firmware-aware
  fallback chain for older/short frames — see below).
- `live.dart` — the live/high-rate stuff: R10, the 0x28 compact-HR stream, the 0x33 IMU
  stream, RR-interval extraction.
- `framing.dart` — the actual byte-level framing: `0xAA` start-of-frame, CRC8 length
  check, CRC32 payload check, the length-based reassembler. This lives HERE, not
  upstream — a previous version of this README claimed there was no framing code in this
  package at all, which stopped being true a while ago.
- `crc.dart` — crc8/crc32.
- `commands.dart` / `control.dart` — command builders (SET_CLOCK, alarms, sync commands,
  etc.) and the control-plane decoders (HELLO, events, command responses, metadata/sync
  markers).
- `constants.dart` — the GATT UUIDs, opcode tables, event IDs.

## The one record that matters most

`parseR24` decodes the 1 Hz historical record — the bulk of what comes off the band
during a sync, one of these per second of wear. Give it the inner payload and you get
back an `R24`, or `null` if it doesn't decode:

```dart
class R24 {
  final int histVersion;     // layout version byte @ inner[1]
  final int tsEpoch;         // unix seconds @ inner[7:11]
  final int tsSubsec;        // sub-seconds @ inner[11:13]
  final int counter;         // record counter @ inner[3:7]
  final int hr;               // heart rate bpm @ inner[17] — 0 means off-wrist, not bradycardia
  final int rrCount;          // 0-4 beat-to-beat intervals this second
  final List<int> rrIntervalsMs;
  final int ppgGreen;         // raw green-LED PPG ADC @ inner[29]
  final int ppgRedIr;         // raw red/IR-LED PPG ADC @ inner[31]
  final List<double> accelG;  // 3x float32 gravity vector @ inner[36:48]
  final int skinContact;      // contact QUALITY @ inner[51] — NOT wear/on-wrist state
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
units — there's no absolute % or °C conversion here, and there shouldn't be one anywhere
downstream either. `skinContact` is a contact-quality signal, not a wear-state flag —
don't use it to decide if the band is on the wrist.

Historical records don't all ship the same layout, and finding that out cost more time
than it should have. `parseR24` decodes v24/v12 verbatim; `FirmwareAwareR24Decoder`
(chain-of-responsibility) is the one to actually reach for on real devices — it tries the
validated 89-byte layout first, then falls back to a 72-byte-floor layout (the true
minimum every field it reads actually needs) for older firmware sending shorter frames,
remembering per-record-version which strategy worked. Other versions (v7/v9/v18/unknown)
route through the v24 field map at a per-version HR offset, gated by a
physiological-plausibility check (HR 25-230bpm AND accel magnitude² 0.25-3.24) — because
without that gate, an implausible unknown-version record gets decoded as if it were real,
and you don't find out until your heart rate graph has a 400 bpm spike in it.

## What's actually verified vs. a plausible read

The header and heart rate are solid — `hr` at `inner[17]` has been checked against a live
stream on a real worn band, not just inferred from the byte layout looking right.

The PPG/accel/optical fields further into the record are a real, working decode too (the
whole map is checked against a frozen TypeScript oracle — `decode_parity_cases.json`,
2934 real captured cases, all passing). But "decodes correctly" and "means something
diagnostic" are two different claims, and it's easy to blur them if you're not careful.
SpO2/skin-temp/ambient are raw ADC counts, no calibration curve behind them — relative
only, always, no exceptions.

## How a sync with the band actually goes

This package doesn't own a Bluetooth connection, it just builds/decodes the bytes. But if
you're integrating it — or just curious what the app built around it actually does — the
conversation with the band looks like this.

Connect, bond, bump the MTU, subscribe to the notify characteristics. Then send
`cmdSetClock`. The band ships with its real-time clock unset, and skip this step and
every record you pull off it gets a garbage timestamp — nothing tells you this up front,
you just find out later when your sleep data says you went to bed in 1970. Then fire
`initPackets` (five packets), which tells the band to start draining its history.

History comes off in batches. After each one, the band sends a marker carrying an 8-byte
token — echo it back exactly with `buildHistoryResultOk`, using a write that waits for
acknowledgement, not fire-and-forget. Get the bytes wrong, or don't wait for the ack, and
the band just re-sends the same batch forever, since as far as it's concerned nothing was
ever confirmed. Whatever's consuming these decoded records needs to actually commit them
to storage before that acknowledgement goes out, not after — a crash mid-sync shouldn't
be able to lose data or tell the band to trim flash it never actually saved.

A couple of other things worth knowing if you're writing a client: live high-rate streams
(R10/0x33) and the historical 1 Hz records use separate sequence-number ranges, so acks
across the two never collide. And `dangerousCmds` in `constants.dart` (flash erase,
reboot, firmware push) exist for a reason — gate them behind an explicit user action,
never auto-send. You really don't want to brick one of these.

The actual client implementation of all this — the real Bluetooth connection, the retry
logic, all of it — lives in [edge](https://github.com/OpenStrap/edge)'s `ble_engine.dart`,
if you want to see it wired up end to end.

## Build it

Pure Dart, no Flutter dependency:

```bash
dart pub get
dart test          # 70 tests, incl. the 2934-case TS-parity suite
```

Run tests from the repo root — the parity fixture (`decode_parity_cases.json`) is
resolved relative to it.

## Adding or fixing a decoder

If you've figured out a field or want to add a new record type: read multi-byte values
little-endian, return `null` (never throw) on malformed/short input, and label anything
you're not 100% sure of as empirical, not verified — a confident wrong label is worse than
an honest "not sure." If you're touching `records.dart`'s multi-version decode chain,
check `FirmwareAwareR24Decoder` first — chances are your case fits the existing fallback
shape rather than needing a new one.

Cross-checking against `_external/noop/`  `bWanShiTong/reverse-engineering-whoop-post/`  for facts/techniques is fine; copying its code is not.
