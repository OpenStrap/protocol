// Command builders — WHOOP 4.0 protocol.
// PURE Dart. The INIT sequence and batch ACK are byte-exact and self-tested.

import 'dart:typed_data';
import 'constants.dart';
import 'framing.dart';
import 'band.dart';

enum WristSelection {
  right(0x01),
  left(0x02);

  const WristSelection(this.value);
  final int value;
}

/// Build a framed command packet: [type][seq][opcode][payload].
/// [profile] selects the generation's frame envelope (default gen4 = WHOOP 4).
/// The inner bytes are identical across generations — command opcodes are
/// shared — so only the envelope differs.
Uint8List buildCommand(int seq, int opcode,
    [List<int> payload = const [0x00],
    BandProfile profile = BandProfile.gen4]) {
  final inner = <int>[
    PacketType.command,
    seq & 0xFF,
    opcode & 0xFF,
    ...payload
  ];
  return buildFrame(inner, profile: profile);
}

/// WHOOP's positive historical-burst result (cmd 0x17).
/// Inner = [0x23][seq][0x17][0x01] + token(8B).
/// `token` is the two 4-byte slices from the HistoryEnd METADATA marker.
Uint8List buildHistoryResultOk(int seq, List<int> token,
    {BandProfile profile = BandProfile.gen4}) {
  if (token.length != 8) {
    throw ArgumentError('batch token must be 8 bytes, got ${token.length}');
  }
  final inner = <int>[
    PacketType.command,
    seq & 0xFF,
    Cmd.historicalDataResult,
    revision1,
    ...token,
  ];
  return buildFrame(inner, profile: profile);
}

/// The strap's negative historical-burst result (cmd 0x17).
/// Payload is a single FAILURE result byte (the band only needs the code).
Uint8List buildHistoryResultFail(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.historicalDataResult, const [0x00], profile);

/// Legacy alias used by the app transport.
Uint8List buildBatchAck(int seq, List<int> token,
        {BandProfile profile = BandProfile.gen4}) =>
    buildHistoryResultOk(seq, token, profile: profile);

/// The 5-packet INIT handshake (hardware-verified, seq 0..4).
/// buildCommand regenerates these byte-for-byte (protocol test asserts it).
/// Send one-at-a-time, ~120ms apart. seq4 triggers the flash drain.
final List<Uint8List> initPackets = [
  buildCommand(0, Cmd.getHelloHarvard, const [0x00]), // seq0
  buildCommand(1, Cmd.getAdvertisingNameHarvard, const [0x00]), // seq1
  buildCommand(2, Cmd.getDataRange, const [0x00]), // seq2
  buildCommand(3, Cmd.getAlarmTime, const [revision1]), // seq3
  buildCommand(4, Cmd.sendHistoricalData, const [0x00]), // seq4 → drain
];

// ── Convenience builders for live ops ──────────────────────────────────────
Uint8List cmdLinkValid(int seq) =>
    buildCommand(seq, Cmd.linkValid, const [0x00]);
Uint8List cmdGetBattery(int seq) =>
    buildCommand(seq, Cmd.getBatteryLevel, const []);
Uint8List cmdGetHello(int seq) =>
    buildCommand(seq, Cmd.getHelloHarvard, const [0x00]);
Uint8List cmdGetHelloModern(int seq) =>
    buildCommand(seq, Cmd.getHello, const [0x01]);
Uint8List cmdAbortHistorical(int seq) =>
    buildCommand(seq, Cmd.abortHistoricalTransmits, const [0x00]);
Uint8List cmdSendHistorical(int seq) =>
    buildCommand(seq, Cmd.sendHistoricalData, const [0x00]);
Uint8List cmdGetClock(int seq) => buildCommand(seq, Cmd.getClock, const []);

/// Set the strap RTC (SET_CLOCK = 0x0A) — WHOOP-EXACT 8-byte payload,
/// hardware-verified by the edge app (`ble_engine.dart setClock()`).
///
/// Payload = TWO little-endian u32s:
///   - `[0:4]` whole seconds (unix epoch, u32 LE)
///   - `[4:8]` SUB-seconds in units of 1/32768 s (a 32768 Hz RTC crystal):
///     `subsec = (millis % 1000) * 32768 ~/ 1000` — 0..32767, a u16 in the low
///     half of the second word; bytes [6:8] stay zero.
///
/// ⚠ SET_CLOCK payload LENGTH IS FIRMWARE-SPECIFIC (8 vs 9 bytes) and
/// load-bearing: a wrong-length set is ACK'd but NOT latched → the RTC stays
/// "lost", the strap refuses to serve type-47 history and records come back
/// dated to 1971. This builder emits the 8-byte form, verified on real
/// hardware. After sending, read the clock back (GET_CLOCK,
/// [cmdGetClock]) to confirm it latched.
///
/// [now] defaults to `DateTime.now()`; pass a fixed instant for tests.
Uint8List cmdSetClock(int seq, {DateTime? now}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final sec = ms ~/ 1000;
  final subsec = ((ms % 1000) * 32768) ~/ 1000; // 0..32767, 1/32768 s units
  final payload = <int>[
    sec & 0xff,
    (sec >> 8) & 0xff,
    (sec >> 16) & 0xff,
    (sec >> 24) & 0xff,
    subsec & 0xff,
    (subsec >> 8) & 0xff,
    0,
    0,
  ];
  return buildCommand(seq, Cmd.setClock, payload);
}

Uint8List cmdGetDataRange(int seq) =>
    buildCommand(seq, Cmd.getDataRange, const [0x00]);
Uint8List cmdReportVersionInfo(int seq) =>
    buildCommand(seq, Cmd.reportVersionInfo, const []);
Uint8List cmdGetBodyLocationAndStatus(int seq) =>
    buildCommand(seq, Cmd.getBodyLocationAndStatus, const []);
Uint8List cmdGetBatteryPackInfo(int seq) =>
    buildCommand(seq, Cmd.getBatteryPackInfo, const []);
Uint8List cmdExitHighFreqSync(int seq) =>
    buildCommand(seq, Cmd.exitHighFreqSync, const []);

Uint8List cmdEnterHighFreqSync(int seq,
    {required int intervalSeconds, required int durationSeconds}) {
  if (intervalSeconds < 0 || intervalSeconds > 0xFFFF) {
    throw ArgumentError.value(
        intervalSeconds, 'intervalSeconds', 'must fit in u16');
  }
  if (durationSeconds < 0 || durationSeconds > 0xFFFF) {
    throw ArgumentError.value(
        durationSeconds, 'durationSeconds', 'must fit in u16');
  }
  final payload = ByteData(5)
    ..setUint8(0, 0x02)
    ..setUint16(1, intervalSeconds, Endian.little)
    ..setUint16(3, durationSeconds, Endian.little);
  return buildCommand(seq, Cmd.enterHighFreqSync, payload.buffer.asUint8List());
}

Uint8List cmdSelectWrist(int seq, WristSelection selection) =>
    buildCommand(seq, Cmd.selectWrist, [revision1, selection.value]);

// Live streams. Optical is WRIST-GATED (0x6B only) — never force (0x6C) or
// persist (0x9A); persistent causes the stuck-green-LED footgun ().
Uint8List cmdToggleHr(int seq, bool on) =>
    buildCommand(seq, Cmd.toggleRealtimeHr, [on ? 0x01 : 0x00]);

/// Toggle the realtime raw (R10/R11) stream (SEND_R10_R11_REALTIME = 0x3F).
///
/// NOTE: sending this with payload `[0x00]` (i.e. `cmdSendR10R11(seq, false)`)
/// is the REAL persistent raw-flood OFF-switch — the off state persists across
/// reconnects. STOP_RAW_DATA (0x52) does nothing. (PROTOCOL_FINDINGS.md:168-169)
Uint8List cmdSendR10R11(int seq, bool on) =>
    buildCommand(seq, Cmd.sendR10R11Realtime, [on ? 0x01 : 0x00]);
Uint8List cmdToggleImu(int seq, bool on) =>
    buildCommand(seq, Cmd.toggleImuMode, [on ? 0x01 : 0x00]);
Uint8List cmdEnableOptical(int seq, bool on) =>
    buildCommand(seq, Cmd.enableOpticalData, [revision1, on ? 0x01 : 0x00]);

/// Play a haptic waveform effect (RUN_HAPTICS_PATTERN = 0x4F).
///
/// [pattern] is a single u8 waveform-effect id. It is RANGE-CHECKED rather than
/// masked: `buildFrame` would happily wrap `cmdBuzz(0, 300)` to effect 44 and
/// hand the strap a perfectly CRC-valid packet playing the wrong effect, with
/// nothing to tell the caller. A value that does not fit a u8 is a caller bug,
/// so throw. (Contrast [cmdSetAlarm], which masks because its payload is a
/// pattern LIST already validated for length.)
Uint8List cmdBuzz(int seq, [int pattern = hapticShortPulse]) {
  if (pattern < 0 || pattern > 0xff) {
    throw ArgumentError.value(
        pattern, 'pattern', 'haptic waveform effect must fit in a u8 (0-255)');
  }
  return buildCommand(seq, Cmd.runHapticsPattern, [pattern, 0, 0, 0, 0]);
}

// ── On-device haptic alarm (SET_ALARM_TIME = 0x42) ─────────────────────────
//
// The strap runs a wall-clock alarm entirely on-device, so it buzzes at the
// scheduled time even with no phone connected. The alarm time is a unix epoch
// split into whole seconds + a 1/32768-s sub-second remainder, exactly like
// SET_CLOCK (0x0A) — the strap's RTC ticks at 32768 Hz.
//
// The alarm has TWO on-wire forms, both hardware-verified from our own device
// captures:
//   • a SHORT form ([cmdSetAlarmSimple]) that carries only the time, and
//   • a RICH form ([cmdSetAlarm]) that carries the time PLUS a haptic waveform
//     pattern.
// On real hardware only the RICH form actually makes the strap buzz: a short
// "time only" write is accepted and ACK'd but the strap never fires it (there
// is no waveform to play). Our earlier 8-byte `[u32 epoch][u32 pad]` attempt
// silently failed for exactly this reason. Prefer [cmdSetAlarm].
//
// gen5: SET_ALARM_TIME(66)/DISABLE_ALARM(69) are opcode-identical across
// generations (§1.4), so [cmdSetAlarm]/[cmdSetAlarmSimple]/[cmdDisableAlarm]/
// [cmdRunAlarm] now take an optional `profile` to build a gen5-framed
// version of the SAME payload shape. That payload shape's gen4
// hardware-verification does NOT transfer automatically — noop's own
// comments mark this REVISION_4 body / DISABLE_ALARM's REVISION_2 body as
// EXPERIMENTAL/hardware-unconfirmed-for-waking on gen5 specifically. Treat
// gen5 alarm calls as feature-flagged/experimental until verified on real
// Maverick/5.0 hardware — do not promise it wakes a gen5 strap.

/// The strap's built-in alarm buzz. Two short waveform effects (47, 152) played
/// with no per-effect loop, the overall waveform looped 7×, for 30 s — this is
/// the default we observed the strap firing for its on-device wake alarm.
const List<int> kDefaultAlarmHaptics = <int>[
  47, 152, 0, 0, 0, 0, 0, 0, // 8× waveform-effect slots (2 active, 6 idle)
  0, 0, //                       loopControlForEffects (u16 LE) = 0
  7, //                          overallWaveformLoopControl = 7
  30, //                         alarmDurationInSeconds = 30
];

// Split a wall-clock instant into the strap's (u32 seconds, u16 sub-seconds)
// representation. Sub-seconds are in units of 1/32768 s (32768 Hz RTC crystal),
// identical to SET_CLOCK.
int _alarmEpochSec(DateTime when) => when.millisecondsSinceEpoch ~/ 1000;
int _alarmSubsec(DateTime when) =>
    ((when.millisecondsSinceEpoch % 1000) * 32768) ~/ 1000; // 0..32767

/// SHORT alarm form (SET_ALARM_TIME = 0x42).
///
/// Payload = 7 bytes: `[0x01][u32 epoch-seconds LE][u16 sub-seconds LE]`.
///   - `0x01` — the form/revision marker for the time-only alarm.
///   - epoch seconds — `when` as a unix epoch, u32 LE.
///   - sub-seconds — `(millis % 1000) * 32768 ~/ 1000`, u16 LE (1/32768 s units).
///
/// ⚠ This form sets the alarm TIME but ships no haptic waveform, so on real
/// hardware the strap ACKs it yet never buzzes. Use [cmdSetAlarm] to actually
/// arm a firing alarm; this is kept for parity / diagnostics only.
Uint8List cmdSetAlarmSimple(int seq, DateTime when,
    {BandProfile profile = BandProfile.gen4}) {
  final sec = _alarmEpochSec(when);
  final subsec = _alarmSubsec(when);
  final p = <int>[
    0x01,
    sec & 0xff,
    (sec >> 8) & 0xff,
    (sec >> 16) & 0xff,
    (sec >> 24) & 0xff,
    subsec & 0xff,
    (subsec >> 8) & 0xff,
  ];
  return buildCommand(seq, Cmd.setAlarmTime, p, profile);
}

/// RICH alarm form (SET_ALARM_TIME = 0x42) — THE form that actually fires.
///
/// Payload = 20 bytes:
/// ```
///   [0x04]                     form/revision marker for the rich alarm
///   [u8  index]                alarm slot index (default 0)
///   [u32 epoch-seconds LE]     when, as a unix epoch (u32 LE)
///   [u16 sub-seconds   LE]     (millis % 1000) * 32768 ~/ 1000 (1/32768 s)
///   [12-byte haptic pattern]   see [kDefaultAlarmHaptics] for the layout
/// ```
/// The 12-byte haptic pattern is:
/// ```
///   [8× u8 waveform-effect]    the effect sequence to play (0 = idle slot)
///   [u16 loopControl LE]       per-effect loop control
///   [u8  overallLoop]          how many times to loop the whole waveform
///   [u8  durationSeconds]      max time to keep buzzing
/// ```
///
/// A haptic pattern is REQUIRED for the alarm to actually buzz — the time-only
/// [cmdSetAlarmSimple] form ACKs without firing. [hapticPattern] defaults to
/// [kDefaultAlarmHaptics] (the strap's stock wake buzz); pass your own 12 bytes
/// to customise. The strap confirms the alarm latched via the
/// STRAP_DRIVEN_ALARM_SET (56) event and its firing via
/// STRAP_DRIVEN_ALARM_EXECUTED (57) / HAPTICS_FIRED (60).
Uint8List cmdSetAlarm(
  int seq,
  DateTime when, {
  int index = 0,
  List<int>? hapticPattern,
  BandProfile profile = BandProfile.gen4,
}) {
  final pattern = hapticPattern ?? kDefaultAlarmHaptics;
  if (pattern.length != 12) {
    throw ArgumentError.value(pattern.length, 'hapticPattern.length',
        'haptic pattern must be 12 bytes');
  }
  final sec = _alarmEpochSec(when);
  final subsec = _alarmSubsec(when);
  final p = <int>[
    0x04,
    index & 0xff,
    sec & 0xff,
    (sec >> 8) & 0xff,
    (sec >> 16) & 0xff,
    (sec >> 24) & 0xff,
    subsec & 0xff,
    (subsec >> 8) & 0xff,
    ...pattern.map((b) => b & 0xff),
  ];
  return buildCommand(seq, Cmd.setAlarmTime, p, profile);
}

/// Fire / test the alarm haptics immediately (RUN_ALARM = 0x44).
///
/// Two forms:
///   - revision 1 (default, [mode] == null): payload `[0x01]`.
///   - revision 2 ([mode] set): payload `[0x02][u8 mode]`, where `mode` selects
///     the run behaviour understood by the firmware.
Uint8List cmdRunAlarm(int seq,
    {int? mode, BandProfile profile = BandProfile.gen4}) {
  final p = mode == null ? const [0x01] : [0x02, mode & 0xff];
  return buildCommand(seq, Cmd.runAlarm, p, profile);
}

/// Disable / cancel the on-device alarm (DISABLE_ALARM = 0x45).
///
/// Payload is the revision byte:
///   - revision 1 (default): `[0x01]`.
///   - revision 2: `[0x02][0xFF]` — the trailing 0xFF is the firmware's
///     "clear all" sentinel for the rev-2 disable.
Uint8List cmdDisableAlarm(int seq,
    {int revision = 1, BandProfile profile = BandProfile.gen4}) {
  final p = revision == 2 ? const [0x02, 0xFF] : [revision & 0xff];
  return buildCommand(seq, Cmd.disableAlarm, p, profile);
}

// ── WHOOP 5 (gen5 / "fd4b") handshake + offload ────────────────────────────
//
// gen5 differs from gen4's 5-packet INIT: the link opens with a single
// CLIENT_HELLO (GET_HELLO = 0x91) written with-response to trigger the
// just-works bond, then the offload is driven by GET_DATA_RANGE (0x22) and
// SEND_HISTORICAL_DATA (0x16) — the SAME opcodes as gen4, but with EMPTY
// payloads (gen4 sends a single 0x00). The HISTORY_END ACK
// ([buildHistoryResultOk]) is byte-structured identically; only the frame
// envelope differs, so pass `profile: BandProfile.gen5`.

/// The gen5 CLIENT_HELLO frame (GET_HELLO = 0x91, payload [0x01]).
///
/// Built through [buildFrame] with the gen5 profile; this reproduces the
/// canonical, hardware-observed 16-byte hello byte-for-byte:
/// `aa 01 08 00 00 01 e6 71 23 01 91 01 36 3e 5c 8d`. A `gen5_test` asserts
/// this equality, which simultaneously validates crc16-modbus + crc32 + the
/// gen5 header layout. Sequence defaults to 1 to match that canonical frame.
Uint8List gen5ClientHello({int seq = 1}) =>
    buildCommand(seq, Cmd.getHello, const [0x01], BandProfile.gen5);

/// gen5 GET_DATA_RANGE (0x22) with the EMPTY payload gen5 expects.
Uint8List cmdGetDataRangeGen5(int seq) =>
    buildCommand(seq, Cmd.getDataRange, const [], BandProfile.gen5);

/// gen5 SEND_HISTORICAL_DATA (0x16) with the EMPTY payload gen5 expects — the
/// command that starts the flash drain.
Uint8List cmdSendHistoricalGen5(int seq) =>
    buildCommand(seq, Cmd.sendHistoricalData, const [], BandProfile.gen5);

// ── gen5 clock (SET_CLOCK_MAVERICK=146 / GET_CLOCK_GEN5=147) ───────────────
//
// gen5 replaces gen4's SET_CLOCK(0x0A)/GET_CLOCK(0x0B) with distinct opcode
// VALUES (§1.4) — the payload shapes are otherwise unverified for gen5 on
// real hardware, so these mirror [cmdSetClock]/[cmdGetClock]'s
// hardware-verified gen4 payload shape (8-byte two-u32 form) as the
// best-supported assumption, clearly marked: hardware verification for gen5
// specifically is still needed before relying on this to actually latch the
// RTC on a real Maverick/5.0 strap.

/// gen5 SET_CLOCK_MAVERICK (146). ASSUMPTION: reuses gen4's hardware-verified
/// 8-byte `[u32 epoch][u16 subsec][pad u16]` payload shape — the opcode VALUE
/// is confirmed gen5-specific, but this payload shape has NOT been confirmed
/// against real gen5 hardware. Verify by reading the clock back
/// ([cmdGetClockGen5]) before trusting it in production.
Uint8List cmdSetClockGen5(int seq, {DateTime? now}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final sec = ms ~/ 1000;
  final subsec = ((ms % 1000) * 32768) ~/ 1000;
  final payload = <int>[
    sec & 0xff,
    (sec >> 8) & 0xff,
    (sec >> 16) & 0xff,
    (sec >> 24) & 0xff,
    subsec & 0xff,
    (subsec >> 8) & 0xff,
    0,
    0,
  ];
  return buildCommand(seq, Cmd.setClockMaverick, payload, BandProfile.gen5);
}

/// gen5 GET_CLOCK_GEN5 (147).
Uint8List cmdGetClockGen5(int seq) =>
    buildCommand(seq, Cmd.getClockGen5, const [], BandProfile.gen5);

// ── gen5 Maverick haptics (RUN_HAPTIC_PATTERN_MAVERICK = 0x13/19) ──────────

/// gen5's Maverick haptic-buzz command — a DIFFERENT opcode from gen4's
/// [cmdBuzz]/RUN_HAPTICS_PATTERN (0x4F/79), not an alias of the same value
/// (§1.4: "79/19 haptics-name-differs-not-value"). Byte-verified 12-byte
/// payload shape: `[0x01, 47, 152, 0,0,0,0,0,0,0,0, overallLoop]` — the same
/// `[47, 152]` waveform-effect pair the strap uses for both its notify-buzz
/// and its wake alarm. [overallLoop] defaults to 1 (a single short buzz);
/// pass a higher value for a longer/repeated pattern.
Uint8List cmdBuzzGen5Maverick(int seq, {int overallLoop = 1}) {
  // Clamp rather than throw — a caller-supplied loop count (e.g. from a UI
  // slider) out of u8 range is a caller mistake, not a reason to crash the
  // buzz command entirely. Matches the reference implementation's behavior.
  final clampedLoop = overallLoop < 0 ? 0 : (overallLoop > 0xff ? 0xff : overallLoop);
  final payload = <int>[
    0x01,
    47,
    152,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    clampedLoop,
  ];
  return buildCommand(
      seq, Cmd.runHapticPatternMaverick, payload, BandProfile.gen5);
}

// ── gen5 SET_CONFIG (opcode 120) + the R22 deep-buffer enable sequence ─────
//
// Opcode-identical to gen4's SET_FF_VALUE, but gen5's R22 deep buffers
// (v20 optical / v21 IMU / v26 PPG — see gen5_records.dart) are OFF by
// default even in the official WHOOP app; a strap will only ever emit v18
// unless this 16-flag sequence is sent first. Byte-verified body shape (a
// real `enable_r22_packets` capture): 40-byte body = ASCII key name
// NUL-padded to 32 bytes, + 1 value byte @ offset 32, + 7 zero bytes.

/// One SET_CONFIG (120) frame: `[0x23][seq][120][0x01][name:32B NUL-padded]
/// [value:1B][zero:7B]`. [name] must fit in 31 bytes (leaving room for the
/// NUL terminator within the 32-byte field) and [value] must be a single
/// ASCII character (this package's config values are always `'1'` or `'2'`).
Uint8List cmdSetConfigGen5(int seq, String name, String value) {
  if (name.codeUnits.any((c) => c > 0x7f) || name.length > 31) {
    throw ArgumentError.value(
        name, 'name', 'must be <=31 ASCII chars (32-byte NUL-padded field)');
  }
  if (value.length != 1 || value.codeUnitAt(0) > 0x7f) {
    throw ArgumentError.value(
        value, 'value', 'must be a single ASCII character');
  }
  final nameBytes = Uint8List(32)..setRange(0, name.length, name.codeUnits);
  final payload = <int>[
    revision1,
    ...nameBytes,
    value.codeUnitAt(0),
    0, 0, 0, 0, 0, 0, 0, // 7 zero bytes
  ];
  return buildCommand(seq, Cmd.setFfValue, payload, BandProfile.gen5);
}

/// SET_DEVICE_CONFIG_VALUE (119) — a distinct, SMALLER sibling of SET_CONFIG
/// (120): a 33-byte body with NO trailing padding (`[name:32B NUL-padded]
/// [value:1B]`, vs 120's 40-byte body). ASSUMPTION: the multiband spec
/// confirms the body is 33 bytes with no padding but does not give a
/// byte-verified real capture for this opcode specifically — this mirrors
/// 120's name/value convention as the best-supported guess. Verify against a
/// real capture before relying on it.
Uint8List cmdSetDeviceConfigValueGen5(int seq, String name, String value) {
  if (name.codeUnits.any((c) => c > 0x7f) || name.length > 31) {
    throw ArgumentError.value(
        name, 'name', 'must be <=31 ASCII chars (32-byte NUL-padded field)');
  }
  if (value.length != 1 || value.codeUnitAt(0) > 0x7f) {
    throw ArgumentError.value(
        value, 'value', 'must be a single ASCII character');
  }
  final nameBytes = Uint8List(32)..setRange(0, name.length, name.codeUnits);
  final payload = <int>[...nameBytes, value.codeUnitAt(0)];
  return buildCommand(seq, Cmd.setDeviceConfigValue, payload, BandProfile.gen5);
}

/// The 16 SET_CONFIG flags (name, value) that unlock gen5's R22 deep buffers
/// (v20/v21/v26), in the exact order + values a real capture verified.
/// INDEX-SENSITIVE — do not reorder or "clean up" (per issue #423's corrected
/// `enable_sig12` value, a prior reordering attempt shipped the wrong value).
const List<(String, String)> kGen5R22EnableFlags = [
  ('enable_r22_packets', '2'),
  ('enable_r22_v2_packets', '2'),
  ('enable_r22_v3_packets', '2'),
  ('enable_r22_v4_packets', '1'),
  ('enable_r22_v5_packets', '2'),
  ('enable_r22_v6_packets', '2'),
  ('enable_r22_v8_packets', '2'),
  ('make_hrfm_visible', '2'),
  ('disable_pip_r26_packets', '2'),
  ('wear_detect_bias', '2'),
  ('hr_ch_switching', '2'),
  ('ir_hw_switching', '2'),
  ('enable_passive_strap_fit_gen5', '1'),
  ('enable_sig11_during_sleep', '2'),
  ('dorset_inhibit_wpt', '2'),
  ('enable_sig12', '1'),
];

/// Build the 16-frame R22 enable sequence (SET_CONFIG per [kGen5R22EnableFlags],
/// sequential `seq` starting at [startSeq]). This is a hard prerequisite for
/// ever receiving v20 (optical)/v21 (IMU)/v26 (PPG) deep buffers from a real
/// gen5 strap — the official WHOOP app never sends it, so a fresh connection
/// without this sequence will only ever yield v18.
List<Uint8List> buildR22EnableSequence({int startSeq = 1}) => [
      for (int i = 0; i < kGen5R22EnableFlags.length; i++)
        cmdSetConfigGen5(
          (startSeq + i) & 0xFF,
          kGen5R22EnableFlags[i].$1,
          kGen5R22EnableFlags[i].$2,
        ),
    ];
