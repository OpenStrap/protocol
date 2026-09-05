// The Ultrahuman Ring Air's wire format, as pure functions. No BLE, no
// database, no crypto — a plain GATT command/response protocol with a single
// opcode byte and no envelope. Everything here takes bytes and returns
// values.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). There is no auth, no
// key exchange and no vendor account anywhere in this protocol, so the reason
// this ships EXPERIMENTAL is not a missing credential — it is that nobody has
// checked a single one of these decoders against a real capture. Every field
// below is TYPED BYTE-READING off a documented offset, not a claim that the
// number it produces means what its name says: HRV, activity level and stress
// carry no documented scale or algorithm, and the two trailing response bytes
// are opaque (a plausible checksum, unverified). A decoder that is confidently
// wrong is worse than one that is silent, so nothing here is exported into an
// edge adapter's declared signals — see the adapter for that half.
//
// THE TWO OTHER PROVEN FACTS. There is no envelope: a request is just
// `[opcode, ...body]` with no length byte and no CRC, and a response is
// `[opcode, result, count, payload…, trailer(2)]` delivered as one or more
// notifications. And there is no trim: `0x04` fetches by record index and
// nothing in this protocol deletes on read or acknowledges a fetch, so a
// re-read is safe.

import 'dart:typed_data';

/// Request opcodes. Only the ones this file builds a request for — see the
/// module doc for why the destructive ones (reset, airplane mode, power
/// saving) have no builder here and never will.
const int kUltrahumanOpSetTime = 0x02;
const int kUltrahumanOpGetRecordings = 0x04;
const int kUltrahumanOpGetTime = 0x05;
const int kUltrahumanOpGetEarliestIndex = 0x07;
const int kUltrahumanOpGetLatestIndex = 0x08;

/// Response result byte.
const int kUltrahumanResultOk = 0x00;
const int kUltrahumanResultEmpty = 0xee;
const int kUltrahumanResultFail = 0xff;

/// Fixed size of one recording record, and the whole of what a `0x04`
/// notification's payload is an array of.
const int kUltrahumanRecordLen = 32;

List<int> _u16le(int v) {
  if (v < 0 || v > 0xffff) {
    throw RangeError.value(v, 'v', 'must fit in an unsigned 16-bit field');
  }
  return <int>[v & 0xff, (v >> 8) & 0xff];
}

List<int> _u32le(int v) {
  if (v < 0 || v > 0xffffffff) {
    throw RangeError.value(v, 'v', 'must fit in an unsigned 32-bit field');
  }
  return <int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];
}

/// Set the ring's real-time clock to [unixSeconds].
List<int> ultrahumanCmdSetTime(int unixSeconds) =>
    <int>[kUltrahumanOpSetTime, ..._u32le(unixSeconds)];

/// Read the ring's real-time clock. No body.
List<int> ultrahumanCmdGetTime() => const <int>[kUltrahumanOpGetTime];

/// Fetch recordings starting at [startIndex], the ring's own record counter —
/// NOT a byte offset and not a timestamp. One request can answer with several
/// notifications, each carrying 0–7 records.
List<int> ultrahumanCmdGetRecordings(int startIndex) =>
    <int>[kUltrahumanOpGetRecordings, ..._u16le(startIndex)];

/// The index of the oldest recording the ring still holds. No body.
List<int> ultrahumanCmdGetEarliestIndex() =>
    const <int>[kUltrahumanOpGetEarliestIndex];

/// The index of the newest recording the ring holds. No body.
List<int> ultrahumanCmdGetLatestIndex() =>
    const <int>[kUltrahumanOpGetLatestIndex];

/// One notification off the response characteristic:
/// `[opcode, result, count, payload…, trailer(2)]`.
///
/// [trailer] is carried but never checked — "likely a checksum" is
/// unverified, and this file does not build a decoder for a field nobody has
/// confirmed the algorithm of.
class UltrahumanResponse {
  final int opcode;
  final int result;
  final int count;
  final Uint8List payload;
  final Uint8List trailer;
  const UltrahumanResponse(
      this.opcode, this.result, this.count, this.payload, this.trailer);

  bool get ok => result == kUltrahumanResultOk;
  bool get empty => result == kUltrahumanResultEmpty;
}

/// Parse one response notification. Null when it is too short to be one —
/// `opcode + result + count + trailer` is 5 bytes, the floor with zero payload
/// — or when a successful `0x04` reply's `count` byte claims a different
/// number of records than its payload actually holds (e.g. count=1 against a
/// 2-byte payload): a caller reading `count` records out of a payload that
/// doesn't hold that many is exactly the "confidently wrong" failure this
/// file exists to avoid, so the malformed frame is rejected outright rather
/// than silently handed back short. Only checked on `kUltrahumanResultOk` —
/// a fail/empty result's `count` byte is not documented to carry this
/// meaning, and still needs to reach the caller so it can abort properly.
UltrahumanResponse? parseUltrahumanResponse(List<int> value) {
  if (value.length < 5) return null;
  final payloadLen = value.length - 5;
  final bytes = Uint8List.fromList(value);
  final opcode = bytes[0];
  final result = bytes[1];
  final count = bytes[2];
  if (opcode == kUltrahumanOpGetRecordings &&
      result == kUltrahumanResultOk &&
      payloadLen != count * kUltrahumanRecordLen) {
    return null;
  }
  return UltrahumanResponse(
    opcode,
    result,
    count,
    Uint8List.sublistView(bytes, 3, 3 + payloadLen),
    Uint8List.sublistView(bytes, 3 + payloadLen),
  );
}

/// One fixed 32-byte recording, decoded structurally.
///
/// THE DOCUMENTED FIELD TABLE ONLY ACCOUNTS FOR 30 OF THE 32 BYTES — offsets
/// 0-29 below, against a record the spec states is 32 bytes long. Bytes 30-31
/// are read by nobody here: there is no documented field at that offset, and
/// a made-up one is exactly the failure this file exists to avoid. An adapter
/// archives the whole 32 bytes verbatim, so nothing is lost, only undecoded.
///
/// EVERY FIELD IS A TYPED READ, NOT A CALIBRATED MEASUREMENT. [hr], [spo2]
/// report 0 for "unmeasured" exactly as the ring's own wire does — this is
/// transcribed, not reinterpreted into null, so a caller checks the same
/// sentinel the device uses. [hrv], [activityLevel] and [stress] have no
/// documented scale or algorithm at all; they are archived by an adapter, not
/// derived from. The three timestamps are independent fields on the wire and
/// are kept independent here — they are known to diverge in workout mode, and
/// collapsing them to one would be a claim nobody has checked.
class UltrahumanRecord {
  final int tsA;
  final int hr;
  final int hrv;
  final int spo2;
  final int measurementType;
  final int tsB;
  final double maxSkinTempC;
  final double minSkinTempC;
  final int tsC;
  final int activityLevel;
  final int steps;
  final int stress;

  const UltrahumanRecord({
    required this.tsA,
    required this.hr,
    required this.hrv,
    required this.spo2,
    required this.measurementType,
    required this.tsB,
    required this.maxSkinTempC,
    required this.minSkinTempC,
    required this.tsC,
    required this.activityLevel,
    required this.steps,
    required this.stress,
  });
}

/// Measurement-type byte values documented for [UltrahumanRecord.measurementType].
const int kUltrahumanMeasureNormal = 1;
const int kUltrahumanMeasureExercise = 5;
const int kUltrahumanMeasureBreathing = 6;
const int kUltrahumanMeasureNotOnFinger = 100;

/// Decode the record at [offset] in [bytes], or null when
/// `offset + 32 > bytes.length` — a truncated record, never guessed at.
UltrahumanRecord? parseUltrahumanRecord(List<int> bytes, int offset) {
  if (offset < 0 || offset + kUltrahumanRecordLen > bytes.length) return null;
  final b = Uint8List.fromList(bytes);
  final d = b.buffer.asByteData(b.offsetInBytes + offset);
  return UltrahumanRecord(
    tsA: d.getUint32(0, Endian.little),
    hr: d.getUint8(4),
    hrv: d.getUint8(5),
    spo2: d.getUint8(6),
    measurementType: d.getUint8(7),
    tsB: d.getUint32(8, Endian.little),
    maxSkinTempC: d.getFloat32(12, Endian.little),
    minSkinTempC: d.getFloat32(16, Endian.little),
    tsC: d.getUint32(20, Endian.little),
    activityLevel: d.getUint16(24, Endian.little),
    steps: d.getUint16(26, Endian.little),
    stress: d.getUint16(28, Endian.little),
  );
}

/// Every record packed into one response's [payload], in order. Stops at the
/// last complete 32-byte record — a payload whose length is not a multiple of
/// 32 has its remainder ignored rather than read out of bounds.
List<UltrahumanRecord> parseUltrahumanRecords(Uint8List payload) {
  final out = <UltrahumanRecord>[];
  for (var off = 0; off + kUltrahumanRecordLen <= payload.length;
      off += kUltrahumanRecordLen) {
    final r = parseUltrahumanRecord(payload, off);
    if (r != null) out.add(r);
  }
  return out;
}
