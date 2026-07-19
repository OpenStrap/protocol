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
    [List<int> payload = const [0x00], BandProfile profile = BandProfile.gen4]) {
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
Uint8List cmdBuzz(int seq, [int pattern = hapticShortPulse]) =>
    buildCommand(seq, Cmd.runHapticsPattern, [pattern, 0, 0, 0, 0]);

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
Uint8List cmdSetAlarmSimple(int seq, DateTime when) {
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
  return buildCommand(seq, Cmd.setAlarmTime, p);
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
}) {
  final pattern = hapticPattern ?? kDefaultAlarmHaptics;
  if (pattern.length != 12) {
    throw ArgumentError.value(
        pattern.length, 'hapticPattern.length', 'haptic pattern must be 12 bytes');
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
  return buildCommand(seq, Cmd.setAlarmTime, p);
}

/// Fire / test the alarm haptics immediately (RUN_ALARM = 0x44).
///
/// Two forms:
///   - revision 1 (default, [mode] == null): payload `[0x01]`.
///   - revision 2 ([mode] set): payload `[0x02][u8 mode]`, where `mode` selects
///     the run behaviour understood by the firmware.
Uint8List cmdRunAlarm(int seq, {int? mode}) {
  final p = mode == null ? const [0x01] : [0x02, mode & 0xff];
  return buildCommand(seq, Cmd.runAlarm, p);
}

/// Disable / cancel the on-device alarm (DISABLE_ALARM = 0x45).
///
/// Payload is the revision byte:
///   - revision 1 (default): `[0x01]`.
///   - revision 2: `[0x02][0xFF]` — the trailing 0xFF is the firmware's
///     "clear all" sentinel for the rev-2 disable.
Uint8List cmdDisableAlarm(int seq, {int revision = 1}) {
  final p = revision == 2 ? const [0x02, 0xFF] : [revision & 0xff];
  return buildCommand(seq, Cmd.disableAlarm, p);
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
