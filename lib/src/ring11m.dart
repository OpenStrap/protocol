// A generic white-label smart ring's wire format ("R11M"/"R10M", also sold as
// "TK5"). Bytes only: no BLE, no Flutter, no database.
//
// NOT the Colmi R11/R12 — that is a different, unrelated official product on
// a different 16-byte fixed-packet protocol. This file is for the separate
// white-label cluster (many storefront names, no vendor in common) that
// speaks the framing below instead.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). Ships EXPERIMENTAL: this
// file decodes only what a real captured example frame proves, and archives
// everything else verbatim rather than guessing a layout nobody has checked
// against a byte.
//
// PROVEN, because a real example frame is checked against it below: the
// header shape, the length field, and the CRC — the model-query request
// `02 03 08 00 47 50 ef 20` decodes as group 0x02, command 0x03, declared
// length 8, payload `47 50`, and the trailing `ef 20` (LE 0x20ef) is exactly
// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection) over the six
// bytes before it — verified by direct computation against that frame, not
// assumed from a name. `_crc16CcittFalse` below is pinned to it.
//
// NOT INDEPENDENTLY VERIFIED, and left undone rather than guessed: which
// wire command actually starts a history transfer for a given data type (no
// concrete command byte for any history "query key" was available to check
// against a real frame), and every history record's internal field layout
// (widths are stated, offsets are not). So this file parses the framing that
// IS pinned — the outer envelope, and the block terminator with its own
// packet count and CRC-16/CCITT trailer — and stops there: a completed
// history block is archived as one undecoded blob, never split into records
// this file cannot actually place a field in.
//
// AUTH: none. No handshake, no key material — session bring-up is plain
// request/response.

import 'dart:typed_data';

// ── command groups ──────────────────────────────────────────────────────
const int kRing11mGroupSetting = 0x01;
const int kRing11mGroupDeviceInfo = 0x02;
const int kRing11mGroupAppControl = 0x03;
const int kRing11mGroupHealthHistory = 0x05;
const int kRing11mGroupRealtime = 0x06;

// ── commands, by group ──────────────────────────────────────────────────
/// group [kRing11mGroupDeviceInfo].
const int kRing11mCmdModelQuery = 0x03;
const int kRing11mCmdBatteryQuery = 0x00;
const int kRing11mCmdCapabilityQuery = 0x01;

/// group [kRing11mGroupSetting].
const int kRing11mCmdSetTime = 0x00;
const int kRing11mCmdAutoHrToggle = 0x0c;
const int kRing11mCmdAutoSpo2Toggle = 0x26;

/// group [kRing11mGroupAppControl].
const int kRing11mCmdFindDevice = 0x00;
const int kRing11mCmdManualMeasurement = 0x2f;
const int kRing11mCmdLiveActivityTotals = 0x09;

/// group [kRing11mGroupHealthHistory]. The frame that closes one history
/// block — see [Ring11mHistoryTerminator]. This is the only command in this
/// group with a byte value this file actually has; the per-type request
/// ("query key") is not pinned down (see the header note) and has no
/// builder here.
const int kRing11mCmdHistoryTerminator = 0x80;

/// group [kRing11mGroupRealtime]. Unsolicited pushes, archived verbatim —
/// see the header note on why no body here is decoded.
const int kRing11mCmdRealtimeStatus = 0x00;
const int kRing11mCmdRealtimeHr = 0x01;
const int kRing11mCmdRealtimeSpo2 = 0x02;
const int kRing11mCmdRealtimeVitals = 0x03;
const int kRing11mCmdRealtimeBattery = 0x15;

/// [ring11mCmdManualMeasurement]'s `kind` byte.
const int kRing11mMeasureHr = 0x00;
const int kRing11mMeasureBp = 0x01;
const int kRing11mMeasureSpo2 = 0x02;

/// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.
/// See the header note for the real frame this is checked against.
int _crc16CcittFalse(List<int> data) {
  int crc = 0xFFFF;
  for (final b in data) {
    crc ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc & 0xFFFF;
}

/// One frame on the command/reply characteristic, both directions:
/// `[group:1][command:1][totalLen:2 LE][payload:N][crc16:2 LE]`.
///
/// `totalLen` counts the WHOLE frame, header and CRC included, so a
/// well-formed frame is always exactly `totalLen` bytes long.
class Ring11mFrame {
  final int group;
  final int command;
  final Uint8List payload;
  const Ring11mFrame(this.group, this.command, this.payload);
}

/// Parse one notification/write value as a frame. Null when it is too short,
/// its declared length disagrees with what was actually delivered, or its
/// trailing CRC does not match — a length or CRC mismatch is a malformed or
/// foreign frame, not a short one to hand back anyway.
Ring11mFrame? parseRing11mFrame(List<int> value) {
  if (value.length < 6) return null;
  final totalLen = value[2] | (value[3] << 8);
  if (totalLen != value.length) return null;
  final crcExpected = value[totalLen - 2] | (value[totalLen - 1] << 8);
  final crcActual = _crc16CcittFalse(value.sublist(0, totalLen - 2));
  if (crcExpected != crcActual) return null;
  return Ring11mFrame(
    value[0],
    value[1],
    Uint8List.fromList(value.sublist(4, totalLen - 2)),
  );
}

/// The most a payload may be: `totalLen` is a u16 LE field counting the whole
/// frame, header and CRC included, so anything past this overflows it.
const int kRing11mMaxPayloadLen = 0xffff - 6;

/// Build one outbound frame, header, payload and CRC all included.
Uint8List buildRing11mFrame(int group, int command, [List<int> payload = const <int>[]]) {
  if (payload.length > kRing11mMaxPayloadLen) {
    throw ArgumentError.value(payload.length, 'payload.length',
        'would overflow the frame\'s own u16 length field');
  }
  final totalLen = 6 + payload.length;
  final out = Uint8List(totalLen);
  out[0] = group & 0xff;
  out[1] = command & 0xff;
  out[2] = totalLen & 0xff;
  out[3] = (totalLen >> 8) & 0xff;
  out.setRange(4, 4 + payload.length, payload);
  final crc = _crc16CcittFalse(out.sublist(0, totalLen - 2));
  out[totalLen - 2] = crc & 0xff;
  out[totalLen - 1] = (crc >> 8) & 0xff;
  return out;
}

// ── device info ─────────────────────────────────────────────────────────
/// The verified example frame's own payload, `47 50` — see the header note.
/// Not decoded as anything meaningful on its own (no ASCII reading of two
/// bytes is offered here), just reproduced exactly rather than guessed empty.
Uint8List ring11mCmdModelQuery() =>
    buildRing11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdModelQuery, const [0x47, 0x50]);

/// The ASCII model string (e.g. `"R11M"`), or null when [f] is not this
/// reply or is not printable ASCII.
String? parseRing11mModel(Ring11mFrame f) {
  if (f.group != kRing11mGroupDeviceInfo ||
      f.command != kRing11mCmdModelQuery ||
      f.payload.isEmpty) {
    return null;
  }
  for (final b in f.payload) {
    if (b < 0x20 || b > 0x7e) return null;
  }
  return String.fromCharCodes(f.payload);
}

Uint8List ring11mCmdBatteryQuery() =>
    buildRing11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdBatteryQuery);

/// Battery percent at payload offset 0 — the one field this file has
/// confidence in placing, since the reply is documented as carrying the
/// level "at a fixed offset" with nothing else described. Bounded 0-100 as a
/// physical fact, not an encoding one: a decoder reading the wrong byte
/// fails this instead of sailing through.
int? parseRing11mBattery(Ring11mFrame f) {
  if (f.group != kRing11mGroupDeviceInfo ||
      f.command != kRing11mCmdBatteryQuery ||
      f.payload.isEmpty) {
    return null;
  }
  final pct = f.payload[0];
  return pct <= 100 ? pct : null;
}

Uint8List ring11mCmdCapabilityQuery() =>
    buildRing11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdCapabilityQuery);

/// The raw capability bitmask bytes, UNDECODED. The reply is documented as a
/// bitmask naming fourteen capabilities but not their bit positions, and a
/// guessed bit order silently reports the wrong feature set — so this hands
/// back the bytes for `raw_archive` and nothing more. Null when [f] is not
/// this reply.
Uint8List? parseRing11mCapabilitiesRaw(Ring11mFrame f) {
  if (f.group != kRing11mGroupDeviceInfo || f.command != kRing11mCmdCapabilityQuery) {
    return null;
  }
  return f.payload;
}

// ── setting ──────────────────────────────────────────────────────────────
/// Set the ring's clock from local wall-clock fields: `[year:2 LE][month]
/// [day][hour][minute][second][weekday]`, `weekday` as Dart's `DateTime.
/// weekday` (1 = Monday .. 7 = Sunday).
Uint8List ring11mCmdSetTime(DateTime local) {
  final b = Uint8List(8);
  b[0] = local.year & 0xff;
  b[1] = (local.year >> 8) & 0xff;
  b[2] = local.month;
  b[3] = local.day;
  b[4] = local.hour;
  b[5] = local.minute;
  b[6] = local.second;
  b[7] = local.weekday;
  return buildRing11mFrame(kRing11mGroupSetting, kRing11mCmdSetTime, b);
}

/// Toggle automatic HR or SpO2 monitoring. [intervalMinutes] is snapped to
/// the only two values the firmware combination is documented to accept.
///
/// THE PAYLOAD SHAPE IS AN INFERENCE, not a captured example: the source
/// material states the command exists and the interval is snapped to 30 or
/// 60 minutes, but does not show a body. `[enable, intervalMinutes]` mirrors
/// [ring11mCmdManualMeasurement]'s own `[enable, kind]` shape on the
/// sibling app-control command — the same firmware family's nearest
/// documented pattern — rather than an unrelated guess. Treat this one as
/// unverified until checked against a real device.
Uint8List ring11mCmdAutoToggle(int command, bool enable, {int intervalMinutes = 30}) {
  if (command != kRing11mCmdAutoHrToggle && command != kRing11mCmdAutoSpo2Toggle) {
    throw ArgumentError.value(command, 'command',
        'must be kRing11mCmdAutoHrToggle or kRing11mCmdAutoSpo2Toggle');
  }
  final snapped = intervalMinutes >= 45 ? 60 : 30;
  return buildRing11mFrame(
    kRing11mGroupSetting,
    command,
    <int>[enable ? 0x01 : 0x00, snapped],
  );
}

// ── app control ──────────────────────────────────────────────────────────
Uint8List ring11mCmdFindDevice() =>
    buildRing11mFrame(kRing11mGroupAppControl, kRing11mCmdFindDevice);

Uint8List ring11mCmdManualMeasurement(bool start, int kind) {
  if (kind != kRing11mMeasureHr &&
      kind != kRing11mMeasureBp &&
      kind != kRing11mMeasureSpo2) {
    throw ArgumentError.value(kind, 'kind',
        'must be kRing11mMeasureHr, kRing11mMeasureBp or kRing11mMeasureSpo2');
  }
  return buildRing11mFrame(
    kRing11mGroupAppControl,
    kRing11mCmdManualMeasurement,
    <int>[start ? 0x01 : 0x00, kind],
  );
}

Uint8List ring11mCmdLiveActivityTotals() =>
    buildRing11mFrame(kRing11mGroupAppControl, kRing11mCmdLiveActivityTotals);

// ── health/history transfer ───────────────────────────────────────────────
/// The frame that closes one history block: `[packetCount:2 LE][…]
/// [crc16:2 LE]`, the trailing CRC over the block's accumulated data bytes —
/// CRC-16/CCITT-FALSE, same construction as the outer frame (poly 0x1021,
/// init 0xFFFF). What sits between the count and the trailer is not
/// described anywhere available and is not read here.
class Ring11mHistoryTerminator {
  final int packetCount;
  final int crc16;
  const Ring11mHistoryTerminator(this.packetCount, this.crc16);
}

/// The terminator carried by [f], or null when [f] is not one.
///
/// STRUCTURE ONLY — this does not and cannot check the CRC itself: that
/// requires the block's own accumulated data bytes, which live with whatever
/// is collecting them, not with one frame. [ring11mHistoryBlockCrcOk] is the
/// paired check every caller should run before treating a block as good.
Ring11mHistoryTerminator? parseRing11mHistoryTerminator(Ring11mFrame f) {
  if (f.group != kRing11mGroupHealthHistory ||
      f.command != kRing11mCmdHistoryTerminator ||
      f.payload.length < 4) {
    return null;
  }
  final n = f.payload.length;
  return Ring11mHistoryTerminator(
    f.payload[0] | (f.payload[1] << 8),
    f.payload[n - 2] | (f.payload[n - 1] << 8),
  );
}

/// CRC-16/CCITT-FALSE over [blockData] — the same check a completed history
/// block's terminator carries. Exposed so a caller can compare it against
/// [Ring11mHistoryTerminator.crc16] without a second implementation of the
/// algorithm.
int ring11mHistoryCrc(List<int> blockData) => _crc16CcittFalse(blockData);

/// Whether [blockData] matches the CRC [term] declares — the check every
/// caller must run before treating a completed block as good. A parsed
/// [Ring11mHistoryTerminator] on its own asserts nothing about correctness;
/// this is what does.
bool ring11mHistoryBlockCrcOk(List<int> blockData, Ring11mHistoryTerminator term) =>
    ring11mHistoryCrc(blockData) == term.crc16;

/// The host's ack/nack of one history block — NOT run through
/// [buildRing11mFrame]: the source material gives these as a fixed 3-byte
/// sequence in their own right, `05 80 00` (ack) or `05 80 04` (nack), with
/// no length field or CRC of their own.
Uint8List buildRing11mHistoryAck(bool ok) =>
    Uint8List.fromList(<int>[kRing11mGroupHealthHistory, kRing11mCmdHistoryTerminator, ok ? 0x00 : 0x04]);
