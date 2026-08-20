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
///
/// On gen5 the failure payload is exactly TWO zero bytes `00 00`, versus the
/// 9-byte `01 + markerA + markerB` success payload from
/// [buildHistoryResultOk]; a one-byte body leaves the strap parsing a
/// truncated result. The gen4 form keeps its established single failure byte
/// until a gen4 capture says otherwise — the two-byte evidence is
/// gen5-scoped.
Uint8List buildHistoryResultFail(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(
      seq,
      Cmd.historicalDataResult,
      profile.isGen5 ? const [0x00, 0x00] : const [0x00],
      profile,
    );

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
/// Read the strap RTC (GET_CLOCK = 0x0B = 11) with an EMPTY body.
///
/// Shared across generations — hardware-verified on WHOOP 5: opcode 11 with
/// an empty body reads a usable time from a real gen5 strap. The reply body
/// is the gen4 shape, `[u32 sec][u32 subsec]` starting at body offset 0.
///
/// On gen5 this is only the FALLBACK path: the normal bootstrap takes its
/// timestamp from the hello response and never sends GET_CLOCK unless hello
/// supplied none.
Uint8List cmdGetClock(int seq, {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getClock, const [], profile);

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
/// SHARED ACROSS GENERATIONS — this is the correct builder for WHOOP 5 too:
/// gen5 takes `SET_CLOCK(10)` carrying
/// `<whole_seconds:u32le><subseconds:u32le>`, and a real gen5 strap answers
/// `SUCCESS` for exactly this 8-byte form. Prefer this over
/// [cmdSetClockGen5], whose opcode 146 is not an established WHOOP opcode.
///
/// [now] defaults to `DateTime.now()`; pass a fixed instant for tests.
Uint8List cmdSetClock(int seq,
    {DateTime? now, BandProfile profile = BandProfile.gen4}) {
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
  return buildCommand(seq, Cmd.setClock, payload, profile);
}

Uint8List cmdGetDataRange(int seq) =>
    buildCommand(seq, Cmd.getDataRange, const [0x00]);
Uint8List cmdReportVersionInfo(int seq) =>
    buildCommand(seq, Cmd.reportVersionInfo, const []);

// Both of these used to send an EMPTY body. gen5 reads the missing first byte
// as revision 0 and rejects the command outright, so neither ever returned
// anything there — the caller just saw silence. The body is the revision byte.
Uint8List cmdGetBodyLocationAndStatus(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getBodyLocationAndStatus, const [revision1], profile);
Uint8List cmdGetBatteryPackInfo(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getBatteryPackInfo, const [revision1], profile);
Uint8List cmdExitHighFreqSync(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.exitHighFreqSync, const [], profile);

// These two took no [profile], so a gen5 caller silently got a gen4-framed
// frame: wrong header length and a crc8 where the strap checks crc16, i.e. a
// frame a gen5 strap cannot parse at all. High-frequency sync simply never
// engaged, while the caller believed it had.
Uint8List cmdEnterHighFreqSync(int seq,
    {required int intervalSeconds,
    required int durationSeconds,
    BandProfile profile = BandProfile.gen4}) {
  if (intervalSeconds < 0 || intervalSeconds > 0xFFFF) {
    throw ArgumentError.value(
        intervalSeconds, 'intervalSeconds', 'must fit in u16');
  }
  if (durationSeconds < 0 || durationSeconds > 0xFFFF) {
    throw ArgumentError.value(
        durationSeconds, 'durationSeconds', 'must fit in u16');
  }
  // gen5 refuses interval <= 60 or duration >= 28800 outright and answers with
  // an "Invalid parameters" reply, so a frame outside that range just means the
  // mode silently never engages — the same class of failure the profile fix
  // above addressed. Enforced for gen5 only: the equivalent bounds on gen4 are
  // unknown, and gen4 is the generation that demonstrably works, so it keeps
  // the permissive u16 range rather than inheriting a limit we cannot check.
  if (profile.isGen5) {
    if (intervalSeconds <= 60) {
      throw ArgumentError.value(intervalSeconds, 'intervalSeconds',
          'gen5 requires > 60 seconds');
    }
    if (durationSeconds >= 28800) {
      throw ArgumentError.value(
          durationSeconds, 'durationSeconds', 'gen5 requires < 28800 seconds');
    }
  }
  final payload = ByteData(5)
    ..setUint8(0, 0x02)
    ..setUint16(1, intervalSeconds, Endian.little)
    ..setUint16(3, durationSeconds, Endian.little);
  return buildCommand(
      seq, Cmd.enterHighFreqSync, payload.buffer.asUint8List(), profile);
}

/// Select the wrist the strap is worn on (0x7B). Also the wrist selector for
/// an ECG reading.
Uint8List cmdSelectWrist(int seq, WristSelection selection,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.selectWrist, [revision1, selection.value], profile);

// Live streams. Never persist optical: the persistent OPTICAL save is 0x99 and
// that is the one that causes the stuck-green-LED / battery-drain footgun; 0x9A
// is the persistent IMU save (a separate command, also blocked).
//
// ⚠ On gen5 the two optical opcodes are the REVERSE of what this comment used
// to claim: 0x6B is the save-to-history toggle and 0x6C is the realtime stream.
// That puts [cmdEnableOptical] (0x6B) next to the 0x99 persistent-save family
// rather than next to a live stream. Unconfirmed for gen4, so the opcodes are
// left pointed where they are — only the description is corrected.
Uint8List cmdToggleHr(int seq, bool on) =>
    buildCommand(seq, Cmd.toggleRealtimeHr, [on ? 0x01 : 0x00]);

/// Toggle the realtime raw (R10/R11) stream (SEND_R10_R11_REALTIME = 0x3F).
///
/// GEN4 ONLY. On gen4, sending this with payload `[0x00]` (i.e.
/// `cmdSendR10R11(seq, false)`) is the REAL persistent raw-flood OFF-switch —
/// the off state persists across reconnects — and STOP_RAW_DATA (0x52) does
/// nothing.
///
/// ⚠ That is INVERTED on gen5, which does not implement 0x3F at all: this
/// command is silently ignored there, and 0x51/0x52 ([cmdRawDataStart] /
/// [cmdRawDataStop]) are the realtime-raw start and stop instead.
Uint8List cmdSendR10R11(int seq, bool on) =>
    buildCommand(seq, Cmd.sendR10R11Realtime, [on ? 0x01 : 0x00]);

/// Toggle the IMU data stream (IMU_SET_DATA_STREAM = 0x6A).
///
/// The body differs by generation: gen4 takes a bare on/off byte, gen5 wants a
/// leading revision byte first. Sending the bare byte to a gen5 strap leaves it
/// reading the state from past the end of the body, so the stream never starts
/// and step calibration stays at zero.
Uint8List cmdToggleImu(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(
      seq,
      Cmd.toggleImuMode,
      profile.isGen5
          ? <int>[revision1, on ? 0x01 : 0x00]
          : <int>[on ? 0x01 : 0x00],
      profile,
    );
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
// The alarm has THREE known on-wire forms:
//   • a 7-byte SHORT form ([cmdSetAlarmSimple]) — time only, no haptic-mode;
//   • a 9-byte REV-1 form ([cmdSetAlarmRev1]) — time + a haptic-mode u16.
//     This is what the official WHOOP app sends (btsnoop capture), and the
//     only form observed to actually EXECUTE on a real WHOOP 4.0; and
//   • a 20-byte RICH form ([cmdSetAlarm]) — time + slot + a haptic waveform.
//
// ⚠ On gen4 the RICH form is a trap: the firmware stores it, echoes it back
// from GET_ALARM_TIME, and confirms it with STRAP_DRIVEN_ALARM_SET (56) —
// but its scheduler never executes it. Extended observation of a real 4.0
// (months of sync logs, 8+ arms) showed zero STRAP_DRIVEN_ALARM_EXECUTED
// (57) and no haptics at any armed target, while the same band armed with
// the REV-1 form fired autonomously at the armed second (events 60 + 57 +
// the one-shot auto-disable 59). Full evidence: issue #32. A GET_ALARM
// readback match therefore proves only that a body was STORED, not that it
// will fire. The SHORT form fails for the same reason it always did — it is
// the REV-1 form minus the trailing haptic-mode u16.
//
// For a gen4 wake alarm, use [cmdSetAlarmRev1].
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

/// Valid alarm slot ids, per generation.
///
/// On gen5, RUN_ALARM and DISABLE_ALARM reject an id of 0, so an alarm written
/// to slot 0 there can never be fired on demand or cancelled afterwards — the
/// usable range is 1..6.
///
/// gen4 is NOT the same and must not inherit that rule: 0 is the default slot
/// the rich form encodes there, and the firmware accepts it. (Note the gen4
/// form that verifiably FIRES — [cmdSetAlarmRev1] — carries no slot byte at
/// all; slot ids only exist in the rich/gen5 encodings.)
int _checkAlarmId(int id, String name, BandProfile profile) {
  final lo = profile.isGen5 ? 1 : 0;
  if (id < lo || id > 6) {
    throw ArgumentError.value(id, name, 'alarm ids are $lo..6 on this band');
  }
  return id;
}

/// Default alarm slot for [profile] — 0 on gen4 (rich form), 1 on gen5.
int _defaultAlarmId(BandProfile profile) => profile.isGen5 ? 1 : 0;

/// SHORT alarm form (SET_ALARM_TIME = 0x42).
///
/// Payload = 7 bytes: `[0x01][u32 epoch-seconds LE][u16 sub-seconds LE]`.
///   - `0x01` — the form/revision marker for the time-only alarm.
///   - epoch seconds — `when` as a unix epoch, u32 LE.
///   - sub-seconds — `(millis % 1000) * 32768 ~/ 1000`, u16 LE (1/32768 s units).
///
/// ⚠ On real hardware the strap ACKs this form yet never buzzes. It is
/// [cmdSetAlarmRev1] minus the trailing haptic-mode u16, and that missing
/// field — not the missing waveform pattern — is why it arms silently. Use
/// [cmdSetAlarmRev1] to arm a firing gen4 alarm; this is kept for parity /
/// diagnostics only.
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

/// REV-1 alarm form (SET_ALARM_TIME = 0x42) — the form a WHOOP 4.0 actually
/// EXECUTES, and the one the official app sends (btsnoop-captured; the wire
/// vector is pinned in the tests).
///
/// Payload = 9 bytes:
/// `[0x01][u32 epoch-seconds LE][u16 sub-seconds LE][u16 haptic-mode LE]`.
///   - `0x01` — the rev-1 form marker, as in [cmdSetAlarmSimple].
///   - epoch / sub-seconds — as everywhere else (1/32768-s units).
///   - haptic-mode — buzz selector. The official app sends 0, the stock wake
///     buzz (observed ~24 s, ended by HAPTICS_TERMINATED event 100). Non-zero
///     modes are accepted on the wire but unexplored — keep the default unless
///     you are experimenting.
///
/// Hardware-verified on a real 4.0: armed with this form the band fired
/// autonomously at the armed second — HAPTICS_FIRED (60),
/// STRAP_DRIVEN_ALARM_EXECUTED (57), then the one-shot auto-disable (59), all
/// stamped at the target epoch — with no phone connected. The 20-byte rich
/// form ([cmdSetAlarm]) latches and confirms identically but was never seen
/// to execute there; see issue #32 for the full evidence.
///
/// Note the confirmation lifecycle: ALARM_SET (56) and the fired events
/// arrive via the band's HISTORY stream on the next sync, not live, and 56
/// only proves the body latched — not that it will fire.
///
/// gen5 straps take the same opcode but a different body (see [cmdSetAlarm]);
/// whether this rev-1 body means anything to a gen5 is untested.
Uint8List cmdSetAlarmRev1(int seq, DateTime when,
        {int hapticMode = 0, BandProfile profile = BandProfile.gen4}) =>
    buildCommand(
        seq, Cmd.setAlarmTime, alarmRev1Payload(when, hapticMode: hapticMode),
        profile);

/// The bare 9-byte payload of the REV-1 alarm form (see [cmdSetAlarmRev1]).
///
/// Exposed separately from the framed command so an app layer that runs its
/// own sequence counter and framing can still source the byte layout from
/// this package instead of duplicating it — the layout has exactly one home.
List<int> alarmRev1Payload(DateTime when, {int hapticMode = 0}) {
  if (hapticMode < 0 || hapticMode > 0xffff) {
    throw ArgumentError.value(
        hapticMode, 'hapticMode', 'haptic mode must fit in a u16');
  }
  final sec = _alarmEpochSec(when);
  final subsec = _alarmSubsec(when);
  return <int>[
    0x01,
    sec & 0xff,
    (sec >> 8) & 0xff,
    (sec >> 16) & 0xff,
    (sec >> 24) & 0xff,
    subsec & 0xff,
    (subsec >> 8) & 0xff,
    hapticMode & 0xff,
    (hapticMode >> 8) & 0xff,
  ];
}

/// RICH alarm form (SET_ALARM_TIME = 0x42).
///
/// ⚠ gen4: this form is STORED but NEVER EXECUTED — the band echoes it from
/// GET_ALARM_TIME and confirms it with event 56 exactly like a live arm, yet
/// the scheduler never fires it (issue #32). For a gen4 wake alarm use
/// [cmdSetAlarmRev1]. On gen5 this rich body (plus the crescendo byte) is the
/// only known arm form, still hardware-unverified for actually waking.
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
/// [hapticPattern] defaults to [kDefaultAlarmHaptics]; pass your own 12 bytes
/// to customise. The strap confirms the alarm latched via the
/// STRAP_DRIVEN_ALARM_SET (56) event and its firing via
/// STRAP_DRIVEN_ALARM_EXECUTED (57) / HAPTICS_FIRED (60) — but on gen4 event
/// 56 is emitted for this form even though it never fires (see above): only
/// 57/60 prove execution.
///
/// [index] is the alarm slot, and the usable range is per-generation (see
/// [_checkAlarmId]): gen4 is 0..6 and DEFAULTS to 0; gen5 is 1..6, because
/// there RUN_ALARM and DISABLE_ALARM reject 0 and an alarm in slot 0 is
/// un-runnable and un-cancellable. Omit [index] to get the right default for
/// the profile.
///
/// GENERATION DIFFERENCE — the trailing byte:
///   • gen4 reads 12 haptic bytes (payload 20). Hardware-verified; unchanged.
///   • gen5 reads one MORE byte (payload 21). The Gen5 revision-4 body ends
///     with **alarm type `00`**, and 0 is the only value ever sent for it.
///     Mind the serializer trap: the body must be 21 bytes, never 20 — the
///     zero-initialised alarm-type byte IS on the wire.
///
///     This package's [crescendo] parameter IS that byte. The name came from a
///     third-party source and is not what the layout calls it; it is kept for
///     source compatibility and still validated as 0/1, but passing 1 means
///     "alarm type 1", an unestablished type — NOT a gentler ramp. Leave it
///     at the default 0.
Uint8List cmdSetAlarm(
  int seq,
  DateTime when, {
  int? index,
  List<int>? hapticPattern,
  /// gen5's trailing body byte — the **alarm type**, always `0` in practice.
  /// See the GENERATION DIFFERENCE note above for why this parameter keeps
  /// its third-party name.
  int crescendo = 0,
  BandProfile profile = BandProfile.gen4,
}) {
  final pattern = hapticPattern ?? kDefaultAlarmHaptics;
  if (pattern.length != 12) {
    throw ArgumentError.value(pattern.length, 'hapticPattern.length',
        'haptic pattern must be 12 bytes');
  }
  final slot =
      _checkAlarmId(index ?? _defaultAlarmId(profile), 'index', profile);
  if (crescendo != 0 && crescendo != 1) {
    throw ArgumentError.value(crescendo, 'crescendo', 'must be 0 or 1');
  }
  final sec = _alarmEpochSec(when);
  final subsec = _alarmSubsec(when);
  final p = <int>[
    0x04,
    slot & 0xff,
    sec & 0xff,
    (sec >> 8) & 0xff,
    (sec >> 16) & 0xff,
    (sec >> 24) & 0xff,
    subsec & 0xff,
    (subsec >> 8) & 0xff,
    ...pattern.map((b) => b & 0xff),
    if (profile.isGen5) crescendo,
  ];
  return buildCommand(seq, Cmd.setAlarmTime, p, profile);
}

/// Read back the armed alarm (GET_ALARM_TIME = 0x43).
///
/// gen4 takes the plain revision byte `[0x01]`. gen5 reads one slot at a time
/// and takes `[0x04][id]` — revision 4 FIRST, then the alarm id (1..6). Sending
/// the bare id is rejected as an unsupported revision for every id but 4, so
/// the read never lands. Every gen5 alarm opcode is rev-then-id (RUN 0x44 is
/// `[0x02][id]`, DISABLE 0x45 is `[0x02][0xFF|id]`); this is not the exception.
Uint8List cmdGetAlarmTime(int seq,
        {int alarmId = 1, BandProfile profile = BandProfile.gen4}) =>
    buildCommand(
      seq,
      Cmd.getAlarmTime,
      profile.isGen5
          ? <int>[0x04, _checkAlarmId(alarmId, 'alarmId', profile)]
          : const <int>[revision1],
      profile,
    );

/// Fire / test the alarm haptics immediately (RUN_ALARM = 0x44).
///
/// Two forms:
///   - revision 1 (gen4 default, [mode] == null): payload `[0x01]`.
///   - revision 2 ([mode] set): payload `[0x02][u8 mode]`, where `mode` selects
///     the run behaviour understood by the firmware.
///
/// gen5 accepts revision 2 ONLY, and `mode` there is the alarm SLOT ID (1..6),
/// so it is required — the rev-1 form does nothing on gen5.
Uint8List cmdRunAlarm(int seq,
    {int? mode, BandProfile profile = BandProfile.gen4}) {
  if (profile.isGen5) {
    if (mode == null) {
      throw ArgumentError.notNull('mode (gen5 RUN_ALARM needs an id, 1..6)');
    }
    _checkAlarmId(mode, 'mode', profile);
  }
  final p = mode == null ? const [0x01] : [0x02, mode & 0xff];
  return buildCommand(seq, Cmd.runAlarm, p, profile);
}

/// Disable / cancel the on-device alarm (DISABLE_ALARM = 0x45).
///
/// Payload is the revision byte:
///   - revision 1 (gen4 default): `[0x01]`.
///   - revision 2: `[0x02][0xFF]` — 0xFF is the "clear all" sentinel — or
///     `[0x02][alarm_id]` to cancel one slot (1..6).
///
/// gen5 accepts revision 2 ONLY; [revision] is ignored there.
Uint8List cmdDisableAlarm(int seq,
    {int revision = 1, int? alarmId, BandProfile profile = BandProfile.gen4}) {
  final rev2 = profile.isGen5 || revision == 2;
  // Only the revision-2 body has somewhere to put an id. The revision-1 form
  // cancels EVERY alarm, so silently dropping the id here would cancel all of
  // them for a caller that asked for one — throw instead of doing something
  // other than what was asked. Not auto-promoted to revision 2: on gen4 the
  // revision-1 disable-all is the form verified on hardware, and quietly
  // sending an unverified body there could leave the alarm armed.
  if (alarmId != null && !rev2) {
    throw ArgumentError.value(
      alarmId,
      'alarmId',
      'cancelling one alarm needs revision 2; revision 1 cancels all of them '
          '(pass revision: 2, or omit alarmId to cancel all)',
    );
  }
  final target =
      alarmId == null ? 0xFF : _checkAlarmId(alarmId, 'alarmId', profile);
  final p = rev2 ? [0x02, target] : [revision & 0xff];
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
// VALUES (§1.4). The bodies are NOT gen4's 8-byte two-u32 form — see each
// builder's own doc for the shape it sends. Still unverified against a real
// strap end to end: the bytes are right, but nothing here has watched an RTC
// actually latch.

/// gen5 SET_CLOCK_MAVERICK (146) — **UNVERIFIED; prefer [cmdSetClock] (10).**
///
/// Body is `[0x01][u32 epoch][u16 subsec]`.
///
/// Opcode **146 is not an established WHOOP opcode**, and no "Maverick clock"
/// command is known to exist. What IS established for gen5: `SET_CLOCK(10)`
/// with `<u32 sec><u32 subsec>`, for which a real gen5 strap answers
/// `SUCCESS` while `GET_CLOCK(11)` reads the time back.
///
/// So this builder sends a guess where a confirmed command exists. That is
/// especially dangerous for the clock: a rejected or no-op'd set is silent —
/// the RTC simply never latches, and every absolute timestamp afterwards
/// (alarms above all) is armed against a clock that was never set.
///
/// Kept only for source compatibility. Do NOT send it to "find out what it
/// does": a clock write is a mutation, not a read.
@Deprecated('opcode 146 is not an established opcode; gen5 '
    'uses SET_CLOCK(10) — use cmdSetClock(seq, profile: BandProfile.gen5)')
Uint8List cmdSetClockGen5(int seq, {DateTime? now}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final sec = ms ~/ 1000;
  final subsec = ((ms % 1000) * 32768) ~/ 1000;
  final payload = <int>[
    revision1,
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

/// gen5 GET_CLOCK_GEN5 (147) — **UNVERIFIED; prefer [cmdGetClock] (11).**
///
/// Takes a `[0x01]` revision body. Same problem as [cmdSetClockGen5]: opcode
/// 147 is not an established WHOOP opcode, while `GET_CLOCK(11)` with an
/// EMPTY body is hardware-confirmed to answer on a real gen5 strap. Kept for
/// source compatibility only.
@Deprecated('opcode 147 is not an established opcode; gen5 '
    'uses GET_CLOCK(11) — use cmdGetClock(seq, profile: BandProfile.gen5)')
Uint8List cmdGetClockGen5(int seq) =>
    buildCommand(seq, Cmd.getClockGen5, const [revision1], BandProfile.gen5);

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
  final clampedLoop =
      overallLoop < 0 ? 0 : (overallLoop > 0xff ? 0xff : overallLoop);
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
// unless this 16-flag sequence is sent first. Body shape: 65 bytes =
// `[0x01 revision][name:32B NUL-padded ASCII][value:32B NUL-padded ASCII]`.
// (An older note here described a 40-byte, revision-less body with the name at
// offset 0 — that is the form the strap REJECTED, reading the name's first byte
// as the revision. Opcode 120 is a persistent NVM write, so build it with the
// builders below, not from a remembered capture.)

/// A 32-byte NUL-padded ASCII key/value field — the unit both SET_CONFIG (120)
/// and SET_DEVICE_CONFIG_VALUE (119) are built from. [max] leaves room for the
/// NUL terminator inside the field.
Uint8List _asciiField32(String s, String argName, {int max = 31}) {
  if (s.length > max || s.codeUnits.any((c) => c > 0x7f)) {
    throw ArgumentError.value(
        s, argName, 'must be <=$max ASCII chars (32-byte NUL-padded field)');
  }
  return Uint8List(32)..setRange(0, s.length, s.codeUnits);
}

void _checkConfigValue(String value) {
  if (value.length != 1 || value.codeUnitAt(0) > 0x7f) {
    throw ArgumentError.value(
        value, 'value', 'must be a single ASCII character');
  }
}

/// One SET_CONFIG (120) frame: `[0x23][seq][120][0x01][name:32B NUL-padded]
/// [value:32B NUL-padded]` — a 65-byte body. Both fields are the same 32-byte
/// shape; the value field being 32 bytes (not 1 + 7 pad) is why an over-short
/// body used to work by accident: the strap stopped at the first NUL. [name]
/// must fit in 31 bytes and [value] must be a single ASCII character (this
/// package's config values are always `'0'`, `'1'` or `'2'`).
Uint8List cmdSetConfigGen5(int seq, String name, String value) {
  _checkConfigValue(value);
  final payload = <int>[
    revision1,
    ..._asciiField32(name, 'name'),
    ..._asciiField32(value, 'value'),
  ];
  return buildCommand(seq, Cmd.setFfValue, payload, BandProfile.gen5);
}

/// SET_DEVICE_CONFIG_VALUE (119) — the smaller-numbered sibling of SET_CONFIG
/// (120), same 65-byte body: `[0x01][name:32B NUL-padded][value:32B
/// NUL-padded]`. This previously sent a 33-byte body with no revision byte,
/// which the strap read as revision 'n' (the name's first byte) and rejected.
Uint8List cmdSetDeviceConfigValueGen5(int seq, String name, String value) {
  _checkConfigValue(value);
  final payload = <int>[
    revision1,
    ..._asciiField32(name, 'name'),
    ..._asciiField32(value, 'value'),
  ];
  return buildCommand(seq, Cmd.setDeviceConfigValue, payload, BandProfile.gen5);
}

// ⚠ THE OFFICIAL BOOLEAN WRITE VALUES, and nothing else:
//     '1' — enable
//     '2' — DISABLE
// ASCII '0' is NOT a value the boolean writer ever emits: a key
// READING 0 is a raw/unset record, and writing '0' back is not a proven
// restoration of that state — which is exactly why raw-zero keys are skipped
// rather than "restored".
// These are PERSISTENT (NVM) writes: a wrong value survives reboot and
// reconnect, and only writing '0' (or the opposite value) undoes it. Sending
// '2' to a flag named `enable_*` force-DISABLES that feature — which is what
// this list used to do to 13 of its 16 entries, including the very
// `enable_r22_*` packet flags the sequence claims to turn on, plus
// `hr_ch_switching` (degrading the strap's own HR) and `wear_detect_bias`
// (altering on/off-body detection). Get the value right before sending.

/// The SET_CONFIG flags (name, value) that unlock gen5's R22 deep buffers
/// (v20 optical / v21 IMU / v26 PPG). Nothing else is touched: flags that do
/// not gate a deep buffer are deliberately absent, because every entry here is
/// a persistent write to a real user-visible setting.
///
/// This is the FULL set with hardware evidence of producing deep buffers.
/// Order is irrelevant — the strap looks each setting up BY NAME, so this list
/// can be reordered or trimmed freely.
///
/// `disable_pip_r26_packets` is the one double negative: it is the SUPPRESSOR
/// for v26 PIP packets, so it takes '2' (disable the suppressor) to let those
/// packets flow. Every other entry is a plain `enable_*` taking '1'.
const List<(String, String)> kGen5R22EnableFlags = [
  ('enable_r22_packets', '1'),
  ('enable_r22_v2_packets', '1'),
  ('enable_r22_v3_packets', '1'),
  ('enable_r22_v4_packets', '1'),
  ('enable_r22_v5_packets', '1'),
  ('enable_r22_v6_packets', '1'),
  ('enable_r22_v8_packets', '1'),
  ('disable_pip_r26_packets', '2'),
];

/// Entries of [kGen5R22EnableFlags] a caller can choose NOT to write
/// (`buildR22EnableSequence(omitContestedFlags: true)`):
///
///  * `enable_r22_v4_packets` reads raw `0` before any write, and raw zero
///    has no proven restoration value (the boolean writer emits only '1' and
///    '2') — so writing it is a ONE-WAY change to the user's device.
///  * `enable_r22_v8_packets` has no active consumer in firmware 50.40.1.0
///    (the R22 selector runs v6..v2, then variant 1), so writing it persists
///    a setting to no effect. Its observed pre-value is '2', so it IS
///    restorable, unlike v4.
///
/// The DEFAULT still writes both: the full set is the one with hardware
/// evidence of producing deep buffers, and the trimmed variant has none yet.
const Set<String> kGen5R22ContestedFlagNames = {
  'enable_r22_v4_packets',
  'enable_r22_v8_packets',
};

/// Build the R22 enable sequence (one SET_CONFIG per [kGen5R22EnableFlags],
/// sequential `seq` starting at [startSeq]). This is a hard prerequisite for
/// ever receiving v20 (optical)/v21 (IMU)/v26 (PPG) deep buffers from a real
/// gen5 strap — the official WHOOP app never sends it, so a fresh connection
/// without this sequence will only ever yield v18.
///
/// PERSISTENT AND PARTLY IRREVERSIBLE. These are NVM writes that survive
/// reboots, and `enable_r22_v4_packets` cannot be restored once written (see
/// [kGen5R22ContestedFlagNames]). Treat sending this as a one-way change to
/// the user's device and get explicit consent first;
/// [omitContestedFlags] skips the irreversible/dormant pair at the cost of
/// diverging from the hardware-proven sequence.
List<Uint8List> buildR22EnableSequence({
  int startSeq = 1,
  bool omitContestedFlags = false,
}) =>
    _configSequence(
      omitContestedFlags
          ? [
              for (final f in kGen5R22EnableFlags)
                if (!kGen5R22ContestedFlagNames.contains(f.$1)) f
            ]
          : kGen5R22EnableFlags,
      startSeq,
    );

/// UNSAFE — do not use as a restore, and not exported from the package.
///
/// Writes raw '0' to every flag [buildR22EnableSequence] touched. But '0' is
/// NOT a valid boolean write value: the writer emits only '1' (enabled) or
/// '2' (disabled), and a returned '0' is an unset/unknown state, never a
/// real "off". It is also not the observed pre-value — straps read '2' on
/// most of these before any write, and observed values are not uniform
/// factory defaults. Restoring therefore requires a per-flag snapshot
/// (enumerate + GET each value BEFORE the enable sequence, then write each
/// recorded value back with readback), not a blanket '0'. Kept only so the
/// asymmetry is visible; retire once a snapshot-based restore exists.
@Deprecated('writes raw 0, which is not a valid write value or the observed '
    'pre-value; use a snapshot-based restore instead. Not a correct undo.')
List<Uint8List> buildR22RestoreDefaultsSequence({int startSeq = 1}) =>
    _configSequence(
      [for (final f in kGen5R22EnableFlags) (f.$1, '0')],
      startSeq,
    );

List<Uint8List> _configSequence(List<(String, String)> flags, int startSeq) => [
      for (int i = 0; i < flags.length; i++)
        cmdSetConfigGen5((startSeq + i) & 0xFF, flags[i].$1, flags[i].$2),
    ];

// ── Ready-to-wire builders for the rest of the gen5 command surface ────────
//
// Nothing in this package calls these yet. Each is byte-shaped for the strap
// and takes a [profile] so a gen5 caller gets a gen5 envelope; the gen5-only
// opcodes still default to gen4 for signature consistency, and simply do
// nothing if sent to a gen4 strap.

/// Gyroscope on/off (0x96) — `[0x01][0|1]`. The gyro is a real power draw;
/// turn it off when done.
Uint8List cmdGyroEnable(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.gyroEnable, [revision1, on ? 0x01 : 0x00], profile);

/// Read whether the gyroscope is currently enabled (0x98) — `[0x01]`.
Uint8List cmdGyroStatus(int seq, {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.gyroStatus, const [revision1], profile);

/// Start the realtime raw stream (START_RAW_DATA = 0x51) for [durationMs].
///
/// Revision 2 (`[0x02][u32 duration-ms LE]`) is used deliberately: revision 1
/// takes no duration and the strap falls back to 86,400,000 ms — a full day of
/// raw streaming, which flattens the battery. Always bound it, and stop early
/// with [cmdRawDataStop] when finished.
Uint8List cmdRawDataStart(int seq,
    {required int durationMs, BandProfile profile = BandProfile.gen4}) {
  if (durationMs <= 0 || durationMs > 86400000) {
    throw ArgumentError.value(
        durationMs, 'durationMs', 'must be 1..86400000 (a bounded duration)');
  }
  final p = ByteData(5)
    ..setUint8(0, 0x02)
    ..setUint32(1, durationMs, Endian.little);
  return buildCommand(seq, Cmd.startRawData, p.buffer.asUint8List(), profile);
}

/// Stop the realtime raw stream (STOP_RAW_DATA = 0x52) — `[0x01]`.
Uint8List cmdRawDataStop(int seq, {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.stopRawData, const [revision1], profile);

/// Read the custom advertising name (0x8D) — `[0x01]`. gen5's equivalent of
/// gen4's 0x4C, which gen5 does not implement.
Uint8List cmdGetCustomAdvertisingName(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getCustomAdvertisingName, const [revision1], profile);

/// Set the custom advertising name (0x8C) — `[0x01][len u8][ascii][u32 0]`,
/// the same body shape as gen4's 0x4D. The strap copies only 16 body bytes and
/// refuses a length over 15, so the name must be ASCII and <=15 chars — a
/// longer one is rejected or silently truncated.
Uint8List cmdSetCustomAdvertisingName(int seq, String name,
    {BandProfile profile = BandProfile.gen4}) {
  if (name.isEmpty || name.length > 15 || name.codeUnits.any((c) => c > 0x7f)) {
    throw ArgumentError.value(name, 'name', 'must be 1..15 ASCII chars');
  }
  return buildCommand(
    seq,
    Cmd.setCustomAdvertisingName,
    <int>[revision1, name.length, ...name.codeUnits, 0, 0, 0, 0],
    profile,
  );
}

/// How many device-config keys the strap exposes (0x73) — `[0x01]`.
Uint8List cmdGetConfigKeyCount(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getConfigKeyCount, const [revision1], profile);

/// The NEXT config key name (0x74) — `[0x01]`. This is an iterator, not a
/// random-access read: the strap walks an internal cursor that
/// [cmdGetConfigKeyCount] (0x73) resets, so call that first and then this
/// once per key. There is no index to pass.
Uint8List cmdGetConfigKeyName(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getConfigKeyName, const [revision1], profile);

/// How many feature-flag keys the strap exposes (0x75) — `[0x01]`.
Uint8List cmdGetFlagKeyCount(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getFlagKeyCount, const [revision1], profile);

/// The NEXT feature-flag key name (0x76) — `[0x01]`, the same cursor-walk as
/// [cmdGetConfigKeyName], reset by [cmdGetFlagKeyCount] (0x75).
Uint8List cmdGetFlagKeyName(int seq,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getFlagKeyName, const [revision1], profile);

/// Read one device-config value by name (0x79) — `[0x01][name:32B
/// NUL-padded]`, the read counterpart of [cmdSetDeviceConfigValueGen5].
Uint8List cmdGetConfigValue(int seq, String name,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getConfigValue,
        <int>[revision1, ..._asciiField32(name, 'name')], profile);

/// Read one feature-flag value by name (0x80) — same body as
/// [cmdGetConfigValue], different namespace.
Uint8List cmdGetFlagValue(int seq, String name,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getFlagValue,
        <int>[revision1, ..._asciiField32(name, 'name')], profile);

/// Turn the strap's EVENT packet stream on/off (0x30).
///
/// ⚠ Body is the BARE state byte — this opcode takes NO revision byte, unlike
/// almost everything around it. Turning this off silences every EventId.
Uint8List cmdSetEventPackets(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.sendEventPackets, [on ? 0x01 : 0x00], profile);

/// Read the optical front-end (AFE) parameters (0x3E) — `[0x01]`. Read-only;
/// the SET twin (0x3D) is deliberately not built here.
Uint8List cmdGetAfeParams(int seq, {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.getAfeParams, const [revision1], profile);

/// Cancel an in-progress haptic buzz (0x7A) — `[0x01]`.
Uint8List cmdStopHaptics(int seq, {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.stopHaptics, const [revision1], profile);

// ── Filtered reading ("Labrador", record revision 17) ──────────────────────
//
// Three toggles, each body `[revision 01][operation]`:
//
//   124 TOGGLE_LABRADOR_DATA_GENERATION  01=stop  02=start  03=restart
//   125 TOGGLE_LABRADOR_RAW_SAVE         00=disable  01=enable
//   139 TOGGLE_LABRADOR_FILTERED         00=disable  01=enable
//
// The old `cmdEcg*` builders below modelled 124 as a boolean arm/disarm. That
// is wrong at the byte level, not just in naming: `01 01` — what the old
// builder sent to "arm" — is the STOP operation, and `01 00` is not an
// operation the strap defines at all.

/// The operation byte of TOGGLE_LABRADOR_DATA_GENERATION (124) — the
/// filtered-reading (R17) lifecycle. It is an operation selector, not a
/// boolean: there is no `00`.
enum LabradorOperation {
  /// `01` — stop generation. The first command of the stop sequence.
  stop(0x01),

  /// `02` — start generation. Sent after an abort (20), and only once the
  /// prepare step's 139 ON / 125 ON both came back successful.
  start(0x02),

  /// `03` — restart generation. What a retry of the start step sends; there
  /// is no plain resend of [start].
  restart(0x03);

  const LabradorOperation(this.value);
  final int value;
}

/// Drive filtered-reading data generation (TOGGLE_LABRADOR_DATA_GENERATION,
/// 124) — `[0x01][op]`, i.e. `01 01` stop / `01 02` start / `01 03` restart.
///
/// **The full lifecycle** — this builder is only the 124 step of it:
///
/// ```text
/// prepare:  20 (abort)  ->  123 (select wrist)  ->  139 ON  ->  125 ON
/// start:    20 (abort)  ->  124 start        (retry uses 124 restart)
/// stop:     124 stop    ->  139 OFF          ->  125 OFF
/// ```
///
/// i.e. [cmdAbortHistorical] (20), [cmdSelectWrist] (123/0x7B),
/// [cmdLabradorFiltered] (139) and [cmdLabradorRawSave] (125), then this.
///
/// Each command carries the standard five-second timeout, and the aggregate
/// must be REJECTED if any single response is missing or unsuccessful.
///
/// **Failure characteristics — the caller owns them.** There is no retry loop
/// and no automatic compensating rollback anywhere in this surface: a partial
/// startup leaves components enabled on the strap. Carry a durable recovery
/// guard (one that survives an app restart, because the strap's state does)
/// and always attempt all three OFF commands on cleanup — stop, 139 OFF,
/// 125 OFF — even when an earlier one failed.
///
/// **Some WHOOP 5 units reject the feature outright:** 20 and 123 succeed
/// while BOTH 139 ON and 125 ON answer `FAILURE`. That correctly prevents the
/// 124 start, and it is a normal path to handle — not a transport error and
/// not something a retry fixes.
Uint8List cmdLabradorDataGeneration(int seq, LabradorOperation op,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.toggleLabradorDataGeneration,
        [revision1, op.value], profile);

/// Enable/disable the filtered-reading RAW save (TOGGLE_LABRADOR_RAW_SAVE,
/// 125) — `[0x01][0|1]`. Part of the prepare step (ON) and of the stop step
/// (OFF); see [cmdLabradorDataGeneration] for the sequence.
Uint8List cmdLabradorRawSave(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(
        seq, Cmd.toggleLabradorRawSave, [revision1, on ? 0x01 : 0x00], profile);

/// Enable/disable the filtered trace (TOGGLE_LABRADOR_FILTERED, 139) —
/// `[0x01][0|1]`. Part of the prepare step (ON) and of the stop step (OFF);
/// see [cmdLabradorDataGeneration] for the sequence. Arrives as record
/// revision 17.
Uint8List cmdLabradorFiltered(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.toggleLabradorFiltered, [revision1, on ? 0x01 : 0x00],
        profile);

/// Arm / disarm an ECG reading (ECG main control, 0x7C) — `[0x01][0|1]`.
///
/// **Wrong bytes, kept only for source compatibility.** Opcode 124 is
/// TOGGLE_LABRADOR_DATA_GENERATION and its second byte is an operation, not a
/// flag: `cmdEcgControl(seq,
/// true)` emits `01 01`, which is the **STOP** operation, and
/// `cmdEcgControl(seq, false)` emits `01 00`, which is not a defined
/// operation at all. Use [cmdLabradorDataGeneration].
@Deprecated('opcode 124 takes an OPERATION byte, not a bool: this builder\'s '
    '`true` sends 01 01 = the STOP operation, and `false` sends the undefined '
    '01 00 — use cmdLabradorDataGeneration(seq, LabradorOperation.start)')
Uint8List cmdEcgControl(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    buildCommand(seq, Cmd.toggleLabradorDataGeneration,
        [revision1, on ? 0x01 : 0x00], profile);

/// Start/stop the raw ECG trace (0x7E) — `[0x01][on]`.
///
/// **Wrong opcode, kept only for source compatibility.** 0x7E (126) is not
/// an established WHOOP 5 opcode — origin unknown, most likely gen4 or
/// third-party lore. The raw save of a filtered
/// reading is TOGGLE_LABRADOR_RAW_SAVE (125): use [cmdLabradorRawSave], which
/// emits the identical `01 00` / `01 01` body on the opcode the strap
/// actually implements.
@Deprecated('opcode 126 (0x7E) is not an established WHOOP 5 opcode '
    '— the raw save is TOGGLE_LABRADOR_RAW_SAVE (125): use '
    'cmdLabradorRawSave(seq, on)')
Uint8List cmdEcgSendRaw(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    // ignore: deprecated_member_use_from_same_package
    buildCommand(
        seq, Cmd.ecgSendRawData, [revision1, on ? 0x01 : 0x00], profile);

/// Start/stop the filtered ECG trace (0x8B) — `[0x01][on]`.
///
/// Body-correct: this is TOGGLE_LABRADOR_FILTERED (139) under its old name,
/// and the bytes are unchanged. Renamed only, so [cmdLabradorFiltered] is a
/// drop-in replacement.
@Deprecated('renamed: opcode 139 is TOGGLE_LABRADOR_FILTERED and the trace is '
    'a filtered reading, not an ECG — use cmdLabradorFiltered(seq, on) '
    '(identical bytes)')
Uint8List cmdEcgSendFiltered(int seq, bool on,
        {BandProfile profile = BandProfile.gen4}) =>
    cmdLabradorFiltered(seq, on, profile: profile);
