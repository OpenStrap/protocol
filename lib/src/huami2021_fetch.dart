// Huami2021/ZeppOS history fetch (control char 0004, data char 0005):
//
//   app  -> 0004  [0x01, type] | time8(since)
//   dev  -> 0004  [0x10, 0x01, status, expected u32, year u16, mo, d, h, mi, s]
//   app  -> 0004  [0x02]                           (skip if expected == 0)
//   dev  -> 0005  [counter u8, payload...] x n
//   dev  -> 0004  [0x10, 0x02, status]
//   app  -> 0004  [0x03, 0x09]   (0x09 = ack and KEEP data on the strap)
//
// Unlike the transport and handshake layers, there is no captured byte
// stream to check this against — only the documented shape. The logic here
// (counter contiguity, byte-count validation, paging) is pure state
// tracking and is tested by construction; the BYTE LAYOUT of the requests
// and replies is unverified against a real device.

import 'dart:typed_data';

/// The `type` byte each fetch start request carries — the same numbering
/// as the record types in `huami2021_records.dart`.
const int kHuami2021TypeActivity = 0x01;
const int kHuami2021TypeManualHr = 0x02;
const int kHuami2021TypeStressManual = 0x12;
const int kHuami2021TypeStress = 0x13;
const int kHuami2021TypeSpo2Spot = 0x25;
const int kHuami2021TypeSpo2Sleep = 0x26;
const int kHuami2021TypeTemperature = 0x2E;
const int kHuami2021TypeRespiratoryRate = 0x38;
const int kHuami2021TypeRestingHr = 0x3A;
const int kHuami2021TypeMaxHr = 0x3D;
const int kHuami2021TypeHrv = 0x49;
const int kHuami2021TypeHrvSdnn = 0x4E;
const int kHuami2021TypePai = 0x0D;
const int kHuami2021TypeOdiSummary = 0x4A;
const int kHuami2021TypeSleep = 0x48;
const int kHuami2021TypeWorkout = 0x05;

/// `[0x02]`: "send the data for the round just started."
const List<int> kHuami2021FetchSendData = [0x02];

/// `[0x03, 0x09]`: ack the round and tell the strap to KEEP its copy. Never
/// send `0x03` with anything else — that would be the delete form, and this
/// protocol never trims (unlike WHOOP's offload, which this is not).
const List<int> kHuami2021FetchAckKeep = [0x03, 0x09];

/// `time8`: local wall-clock `since`, as year u16 LE, month, day, hour,
/// minute, 0 (seconds), then `(utcOffsetMinutes / 15) & 0xFF`.
Uint8List huami2021Time8(DateTime localSince, int utcOffsetMinutes) {
  final out = Uint8List(8);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, localSince.year, Endian.little);
  out[2] = localSince.month;
  out[3] = localSince.day;
  out[4] = localSince.hour;
  out[5] = localSince.minute;
  out[6] = 0;
  out[7] = (utcOffsetMinutes ~/ 15) & 0xFF;
  return out;
}

/// `[0x01, type] | time8(since)`: the fetch start request.
Uint8List huami2021FetchStartRequest(int type, DateTime localSince, int utcOffsetMinutes) =>
    Uint8List.fromList([0x01, type, ...huami2021Time8(localSince, utcOffsetMinutes)]);

/// The device's reply to a start request: `[0x10, 0x01, status, expected
/// u32, year u16, mo, d, h, mi, s]`. `roundStartMs` is built from the
/// reply's own date fields, read as a plain local wall-clock value (no
/// timezone applied here — that is the caller's job, same as every other
/// local-time field in this protocol).
class Huami2021FetchStart {
  const Huami2021FetchStart(
      {required this.status, required this.expected, required this.roundStart});
  final int status;
  final int expected;
  final DateTime roundStart;

  bool get ok => status == 0x01;
  bool get hasData => ok && expected > 0;
}

/// Parses a start reply, or null if [b] isn't one (too short, or not this
/// shape).
Huami2021FetchStart? parseHuami2021FetchStart(Uint8List b) {
  if (b.length < 13 || b[0] != 0x10 || b[1] != 0x01) return null;
  final bd = ByteData.sublistView(b);
  final status = b[2];
  final expected = bd.getUint32(3, Endian.little);
  final year = bd.getUint16(7, Endian.little);
  final month = b[9];
  final day = b[10];
  final hour = b[11];
  final minute = b[12];
  final second = b.length > 13 ? b[13] : 0;
  // Dart's DateTime constructor NORMALISES an out-of-range field instead of
  // throwing (month 0 becomes the previous December, for instance), so an
  // all-zero or corrupted date silently becomes a real-looking date in the
  // wrong year rather than failing loudly. Validate the fields explicitly
  // before constructing, rather than relying on an exception that never
  // comes.
  final plausible = month >= 1 &&
      month <= 12 &&
      day >= 1 &&
      day <= 31 &&
      hour <= 23 &&
      minute <= 59 &&
      second <= 59 &&
      year >= 2000 &&
      year <= 2100;
  final roundStart =
      plausible ? DateTime(year, month, day, hour, minute, second) : DateTime(1970);
  return Huami2021FetchStart(status: status, expected: expected, roundStart: roundStart);
}

/// `[0x10, 0x02, status]`: the round is over. Returns null if [b] isn't
/// this shape.
int? parseHuami2021FetchRoundEnd(Uint8List b) {
  if (b.length < 3 || b[0] != 0x10 || b[1] != 0x02) return null;
  return b[2];
}

/// Reassembles the `[counter, payload...]` data packets of one round.
/// [ok] goes false the moment a counter isn't `(prev+1) & 0xFF` from 0 —
/// from then on the round is not trustworthy and must be discarded, never
/// decoded. A repeated final packet is not handled specially here (the
/// spec only documents the counter-gap and short-count failure modes);
/// decoders are tolerant of a harmless trailing partial record regardless.
class Huami2021FetchBuffer {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _next = 0;
  bool ok = true;

  void add(List<int> packet) {
    if (!ok || packet.isEmpty) return;
    if (packet[0] != (_next & 0xff)) {
      ok = false;
      return;
    }
    _next++;
    _bytes.add(packet.sublist(1));
  }

  Uint8List get bytes => _bytes.toBytes();
}

/// Whether an accumulated round's byte count matches what the start reply
/// announced. Type `0x01`'s `expected` is a RECORD count, of 8- or 4-byte
/// records; every other type's `expected` is a plain byte count.
bool huami2021FetchCountMatches(int type, int expected, int actualBytes) {
  if (type == kHuami2021TypeActivity) {
    return actualBytes == expected * 8 || actualBytes == expected * 4;
  }
  return expected == actualBytes;
}

/// The paging advance when a round decoded to zero samples but did carry
/// raw bytes (types 0x01 and 0x13 only — a new strap answers every window
/// before its first real day with filler, and without this the pager never
/// gets past it). Minutes, clamped to 1-1440. For activity, pass the
/// announced [recordCount] when there is one: the byte length alone can't
/// tell six 4-byte records from three 8-byte ones.
int huami2021FetchGapSkipMinutes(int type, int rawLen, {int? recordCount}) {
  if (type == kHuami2021TypeActivity && recordCount != null && recordCount > 0) {
    return recordCount.clamp(1, 1440);
  }
  final recordSize = switch (type) {
    kHuami2021TypeActivity => rawLen % 8 == 0 ? 8 : 4,
    kHuami2021TypeStress => 1,
    _ => throw ArgumentError('gap-skip only applies to activity and stress'),
  };
  if (recordSize == 0) return 1;
  final minutes = rawLen ~/ recordSize;
  return minutes.clamp(1, 1440);
}

/// Workouts page by "latest decoded workout start + 1 min", but a round
/// that brings nothing newer should still advance — by 5 minutes, up to 40
/// times — rather than stall forever on a strap whose wall clock drifted
/// across a DST change relative to when the workout was actually recorded.
const int kHuami2021WorkoutStallAdvanceMinutes = 5;
const int kHuami2021WorkoutStallMaxAdvances = 40;
