// Command builders — WHOOP 4.0 protocol.
// PURE Dart. The INIT sequence and batch ACK are byte-exact and self-tested.

import 'dart:typed_data';
import 'constants.dart';
import 'framing.dart';

/// Build a framed command packet: [type][seq][opcode][payload].
Uint8List buildCommand(int seq, int opcode, [List<int> payload = const [0x00]]) {
  final inner = <int>[PacketType.command, seq & 0xFF, opcode & 0xFF, ...payload];
  return buildFrame(inner);
}

/// The historical-sync acknowledgement (cmd 0x17).
/// Inner = [0x23][seq][0x17][0x01] + token(8B)  -> 12-byte inner, 20-byte frame.
/// `token` is bytes inner[13:21] of the HistoryEnd METADATA marker.
/// THIS IS THE FRAGILE BREAKING POINT — verified byte-exact ().
Uint8List buildBatchAck(int seq, List<int> token) {
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
  return buildFrame(inner);
}

/// The 5-packet INIT handshake (HCI-snoop verbatim, seq 0..4).
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
Uint8List cmdLinkValid(int seq) => buildCommand(seq, Cmd.linkValid, const [0x00]);
Uint8List cmdGetBattery(int seq) => buildCommand(seq, Cmd.getBatteryLevel, const []);
Uint8List cmdGetHello(int seq) => buildCommand(seq, Cmd.getHelloHarvard, const [0x00]);
Uint8List cmdAbortHistorical(int seq) =>
    buildCommand(seq, Cmd.abortHistoricalTransmits, const [0x00]);
Uint8List cmdSendHistorical(int seq) =>
    buildCommand(seq, Cmd.sendHistoricalData, const [0x00]);
Uint8List cmdGetClock(int seq) => buildCommand(seq, Cmd.getClock, const []);
Uint8List cmdGetDataRange(int seq) =>
    buildCommand(seq, Cmd.getDataRange, const [0x00]);
Uint8List cmdExitHighFreqSync(int seq) =>
    buildCommand(seq, Cmd.exitHighFreqSync, const [0x00]);

// Live streams. Optical is WRIST-GATED (0x6B only) — never force (0x6C) or
// persist (0x9A); persistent causes the stuck-green-LED footgun ().
Uint8List cmdToggleHr(int seq, bool on) =>
    buildCommand(seq, Cmd.toggleRealtimeHr, [on ? 0x01 : 0x00]);
Uint8List cmdSendR10R11(int seq, bool on) =>
    buildCommand(seq, Cmd.sendR10R11Realtime, [on ? 0x01 : 0x00]);
Uint8List cmdToggleImu(int seq, bool on) =>
    buildCommand(seq, Cmd.toggleImuMode, [on ? 0x01 : 0x00]);
Uint8List cmdEnableOptical(int seq, bool on) =>
    buildCommand(seq, Cmd.enableOpticalData, [revision1, on ? 0x01 : 0x00]);
Uint8List cmdBuzz(int seq, [int pattern = hapticShortPulse]) =>
    buildCommand(seq, Cmd.runHapticsPattern, [pattern, 0, 0, 0, 0]);

/// Set the band's on-device haptic alarm (SET_ALARM_TIME = 0x42). The firmware
/// buzzes at [epochSeconds] (a wall-clock unix epoch, seconds) independently of
/// the app, so the alarm fires even with no BLE connection.
///
/// Payload layout: `[u32 epoch LE][u32 0 pad]` — 8 bytes, mirroring SET_CLOCK
/// (0x0A), which is the directly-analogous "write a wall-clock u32" command.
///
/// CONFIRMED:
///   - Opcode 0x42 is the SET counterpart of GET_ALARM_TIME (0x43); DISABLE is
///     a separate opcode (0x45). The GET_ALARM_TIME *response* decodes its epoch
///     as a u32 LE (see parseCommandResponse → `alarm_epoch = u32(payload, 1)`),
///     confirming the alarm time is a u32 LE unix epoch in SECONDS.
///
/// INFERRED (verify on real hardware):
///   - The exact SET payload length/shape. We use the same `[u32 epoch, u32 pad]`
///     8-byte shape as SET_CLOCK because alarm time is the same kind of value and
///     the constants table already annotates 0x42 as `[u32 epoch LE, 0,0,0,0]`.
///     NOTE: prior art shows SET_CLOCK's accepted length is FIRMWARE-SPECIFIC —
///     a wrong length may ACK without latching. If the alarm fails to stick on
///     hardware, try trimming/padding this payload to match the firmware.
///   - The GET response has a leading byte before the epoch (decoded at offset 1,
///     and GET is sent with a `[0x01]` read/revision byte). The SET direction is
///     assumed NOT to need that leading byte (matching SET_CLOCK, which sends the
///     u32 first with no toggle prefix). If SET is rejected, prepend `revision1`.
Uint8List cmdSetAlarm(int seq, int epochSeconds) {
  final p = Uint8List(8);
  final bd = ByteData.sublistView(p);
  bd.setUint32(0, epochSeconds & 0xFFFFFFFF, Endian.little);
  // bytes [4:8] stay zero — the u32 pad, as with SET_CLOCK.
  return buildCommand(seq, Cmd.setAlarmTime, p);
}
