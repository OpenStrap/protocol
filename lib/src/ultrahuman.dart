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
// number it produces means what its name says: the two HRV bytes and activity
// carry no documented algorithm, and the two trailing response bytes are
// opaque (a plausible checksum, unverified). A decoder that is confidently
// wrong is worse than one that is silent, so only the per-record HR is
// surfaced (as sparse `hrSparse` samples, outside derivation via
// `kDerivableSources`); HRV, SpO2 and skin temperature travel only as
// vendor-attributed observations. See the adapter for that half.
//
// THE TWO OTHER PROVEN FACTS. There is no envelope: a request is just
// `[opcode, ...body]` with no length byte and no CRC, and a response is
// `[opcode, result, count, payload…, trailer(2)]` delivered as one or more
// notifications. And there is no trim: `0x04` fetches by record index and
// nothing in this protocol deletes on read or acknowledges a fetch, so a
// re-read is safe.

import 'dart:typed_data';

/// Request opcodes. Only the ones this file builds a request for. The
/// destructive ones have no builder here and never will: 0x0d, 0x17 (device
/// reset / shipping mode), 0x18, 0x19, 0x60, 0x61, 0x70 (airplane mode),
/// 0x98 (software reset), 0x99, 0xbf, 0xd1-0xd4 (power saving), 0xf0, 0xfb
/// and 0xfc.
const int kUltrahumanOpSetTime = 0x02;
const int kUltrahumanOpGetRecordings = 0x04;
const int kUltrahumanOpGetTime = 0x05;
const int kUltrahumanOpGetEarliestIndex = 0x07;
const int kUltrahumanOpGetLatestIndex = 0x08;

/// Response result byte. Anything other than ok or empty (busy, invalid
/// command, no time set, a measurement already running, ...) is a failure;
/// [kUltrahumanResultFail] is only the most common one.
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
/// NOT a byte offset and not a timestamp. One request streams the history
/// from there as several notifications; how many records fit in one depends
/// on the negotiated MTU (7 at 247), so a short frame is not the last one.
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

  /// Neither ok nor empty: the command failed, whatever the code says.
  bool get failed => !ok && !empty;
}

/// Parse one response notification. Null when it is too short to be one —
/// `opcode + result + count + trailer` is 5 bytes, the floor with zero payload.
///
/// [UltrahumanResponse.count] is NOT checked against the payload length. The
/// ring only promises that a `0x04` data frame has an ok result and a
/// non-zero count; the records are however many whole 32-byte records fit
/// between offset 3 and the trailer ([parseUltrahumanRecords] takes the floor).
UltrahumanResponse? parseUltrahumanResponse(List<int> value) {
  if (value.length < 5) return null;
  final payloadLen = value.length - 5;
  final bytes = Uint8List.fromList(value);
  return UltrahumanResponse(
    bytes[0],
    bytes[1],
    bytes[2],
    Uint8List.sublistView(bytes, 3, 3 + payloadLen),
    Uint8List.sublistView(bytes, 3 + payloadLen),
  );
}

/// One fixed 32-byte recording, decoded structurally.
///
/// LAYOUT (all little-endian): `0` u32 tsA (Unix s, PPG) · `4` hr · `5` HRV
/// (RMSSD) · `6` spo2 · `7` HR quality / ring state · `8` u32 tsB
/// (temperature) · `12` f32 skin (object) temp degC · `16` f32 ambient temp
/// degC · `20` u32 tsC (motion) · `24` u16 activity · `26` u16 steps · `28`
/// HRV (SDNN) · `29` temperature quality · `30` u16 the record's own index.
/// There is no stress field. An adapter archives all 32 bytes verbatim.
///
/// [hr] and [spo2] report 0 for "unmeasured" exactly as the ring's own wire
/// does — transcribed, not reinterpreted into null. [hrv], [hrvSdnn] and
/// [activity] are the ring's own numbers with no published algorithm:
/// vendor values, never an input to our analytics. The three timestamps are independent fields on the wire and
/// are kept independent here — they are known to diverge in workout mode, and
/// collapsing them to one would be a claim nobody has checked.
class UltrahumanRecord {
  final int tsA;
  final int hr;

  /// RMSSD, ms.
  final int hrv;
  final int spo2;

  /// Whether this record's optical readings are usable, and what the ring was
  /// doing — see [ultrahumanHrQualityValid].
  final int hrQuality;
  final int tsB;

  /// The skin-facing (object) sensor. NaN when the ring had no reading.
  final double skinTempC;

  /// The ambient sensor — not skin temperature.
  final double ambientTempC;
  final int tsC;
  final int activity;
  final int steps;

  /// SDNN, ms. Raw byte, no rescaling.
  final int hrvSdnn;

  /// Quality of [skinTempC] and [ambientTempC]; 0 means "do not use".
  final int tempQuality;

  /// The ring's own record index — the same u16 counter `0x04` fetches by.
  final int index;

  const UltrahumanRecord({
    required this.tsA,
    required this.hr,
    required this.hrv,
    required this.spo2,
    required this.hrQuality,
    required this.tsB,
    required this.skinTempC,
    required this.ambientTempC,
    required this.tsC,
    required this.activity,
    required this.steps,
    required this.hrvSdnn,
    required this.tempQuality,
    required this.index,
  });
}

/// [UltrahumanRecord.hrQuality] values. Only the ones a reader is likely to
/// look for; every value the ring sends is still archived verbatim.
const int kUltrahumanHrQualityContact = 0;
const int kUltrahumanHrQualityLegacy = 1;
const int kUltrahumanHrQualityLiveHr = 2;
const int kUltrahumanHrQualityCdtHr = 5;
const int kUltrahumanHrQualityCdtBreathing = 6;
const int kUltrahumanHrQualityStealth = 7;
const int kUltrahumanHrQualityLowConfidence = 9;
const int kUltrahumanHrQualityNoContact = 10;
const int kUltrahumanHrQualityPassiveSleep = 11;
const int kUltrahumanHrQualityCharging = 100;
const int kUltrahumanHrQualityChargingNoContact = 110;

/// True when a record with this [UltrahumanRecord.hrQuality] carries usable
/// HR/HRV/SpO2. Everything else (no contact, charging, live-HR placeholder,
/// sensor errors) is not a reading.
bool ultrahumanHrQualityValid(int q) => const {
      kUltrahumanHrQualityContact,
      kUltrahumanHrQualityLegacy,
      kUltrahumanHrQualityCdtHr,
      kUltrahumanHrQualityCdtBreathing,
      kUltrahumanHrQualityStealth,
      kUltrahumanHrQualityLowConfidence,
      kUltrahumanHrQualityPassiveSleep,
    }.contains(q);

/// Decode the record at [offset] in [bytes], or null when
/// `offset + 32 > bytes.length` — a truncated record, never guessed at.
UltrahumanRecord? parseUltrahumanRecord(List<int> bytes, int offset) {
  if (offset < 0 || offset + kUltrahumanRecordLen > bytes.length) return null;
  final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final d = b.buffer.asByteData(b.offsetInBytes + offset);
  return UltrahumanRecord(
    tsA: d.getUint32(0, Endian.little),
    hr: d.getUint8(4),
    hrv: d.getUint8(5),
    spo2: d.getUint8(6),
    hrQuality: d.getUint8(7),
    tsB: d.getUint32(8, Endian.little),
    skinTempC: d.getFloat32(12, Endian.little),
    ambientTempC: d.getFloat32(16, Endian.little),
    tsC: d.getUint32(20, Endian.little),
    activity: d.getUint16(24, Endian.little),
    steps: d.getUint16(26, Endian.little),
    hrvSdnn: d.getUint8(28),
    tempQuality: d.getUint8(29),
    index: d.getUint16(30, Endian.little),
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
