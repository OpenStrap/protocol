// Command builders — WHOOP 4.0 protocol.
// PURE Dart. The INIT sequence and batch ACK are byte-exact and self-tested.

import 'dart:typed_data';
import 'constants.dart';
import 'framing.dart';

enum WristSelection {
  right(0x01),
  left(0x02);

  const WristSelection(this.value);
  final int value;
}

/// Build a framed command packet: [type][seq][opcode][payload].
Uint8List buildCommand(int seq, int opcode,
    [List<int> payload = const [0x00]]) {
  final inner = <int>[
    PacketType.command,
    seq & 0xFF,
    opcode & 0xFF,
    ...payload
  ];
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
Uint8List cmdSendR10R11(int seq, bool on) =>
    buildCommand(seq, Cmd.sendR10R11Realtime, [on ? 0x01 : 0x00]);
Uint8List cmdToggleImu(int seq, bool on) =>
    buildCommand(seq, Cmd.toggleImuMode, [on ? 0x01 : 0x00]);
Uint8List cmdEnableOptical(int seq, bool on) =>
    buildCommand(seq, Cmd.enableOpticalData, [revision1, on ? 0x01 : 0x00]);
Uint8List cmdBuzz(int seq, [int pattern = hapticShortPulse]) =>
    buildCommand(seq, Cmd.runHapticsPattern, [pattern, 0, 0, 0, 0]);
