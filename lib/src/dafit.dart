// DaFit / MOYOUNG-V2 wire format — the framing spoken by a large cluster of
// unbranded Chinese OEM watches, paired through the "DaFit" or "MOYOUNG"
// companion app and sold under dozens of storefront names. Bytes only: no
// BLE, no Flutter, no database.
//
// NOTHING HERE HAS MET HARDWARE. Ships EXPERIMENTAL (ASSUMPTIONS R6): this
// file decodes NO physiological signal from this family's frames, only the
// framing needed to hold a session open and bank what the band sends. A
// data-bearing reply that goes unacknowledged is documented to leave the
// band stalled and draining its battery fast, so the minimal ack this file
// builds is protocol plumbing, not a derived metric — nothing here turns
// bytes into a heart rate, a step count or a sleep stage.
//
// TRANSPORT is an otherwise-generic Nordic UART Service link (one write
// characteristic, one notify characteristic, no CRC, no encryption).
//
// DATA FRAME (header 0xCD), app<->band, big-endian length fields:
//   [0]     header (0xCD)
//   [1..2]  outer length: byte count from [3] to the end of payload,
//           i.e. 5 + payload.length
//   [3]     command group
//   [4]     protocol version/delimiter — always 0x01
//   [5]     command
//   [6..7]  payload length
//   [8..]   payload
//
// ACK FRAME (header 0xDC), a fixed 8 bytes, sent to keep a data-bearing
// exchange moving:
//   [0] 0xDC  [1..2] 0x00 0x05 (fixed)  [3] command group  [4] 0x01
//   [5..6] (outer length of the frame being acked) + 3
//   [7] 0x01
// This shape does not nest inside the data-frame layout above — it is
// parsed and built separately, never through [parseDafitFrame].

import 'dart:typed_data';

const int kDafitDataHeader = 0xCD;
const int kDafitAckHeader = 0xDC;

const int kDafitGroupGeneral = 0x12;
const int kDafitGroupRequestData = 0x1a;
const int kDafitGroupBandInfo = 0x20;

const int kDafitCmdSetDateTime = 0x01;
const int kDafitCmdSetLanguage = 0x15;
const int kDafitCmdInit1 = 0x0a;
const int kDafitCmdInit2 = 0x0c;
const int kDafitCmdInit3 = 0xff;

/// group [kDafitGroupRequestData].
const int kDafitCmdGetHwInfo = 0x10;

/// group [kDafitGroupBandInfo].
const int kDafitCmdGetBandInfo = 0x02;

const int kDafitValueOn = 0x01;
const int kDafitLangEnglish = 0x01;

/// One parsed data frame ([kDafitDataHeader]). Null for anything else,
/// including this family's own ACK frames — see [parseDafitFrame].
class DafitFrame {
  final int group;
  final int command;
  final Uint8List payload;

  /// The frame's own declared outer length (bytes [1..2]) — kept verbatim,
  /// not recomputed from [payload], so [buildDafitAck] echoes exactly what
  /// the band itself declared rather than this file's own arithmetic.
  final int outerLen;

  const DafitFrame(this.group, this.command, this.payload, this.outerLen);
}

/// Parse one notification as a data frame. Null when it cannot be one —
/// too short, the wrong header (an ACK frame reads `0xDC` here and is
/// correctly rejected), a payload length longer than the bytes actually
/// delivered, or an outer length that disagrees with the payload length —
/// the two are supposed to describe the same frame (`outerLen == 5 +
/// payloadLen`), and a frame where they disagree is malformed, not merely
/// unfamiliar. Accepting it anyway would hand [buildDafitAck] a length to
/// echo back that this frame never actually had.
DafitFrame? parseDafitFrame(List<int> value) {
  if (value.length < 8 || value[0] != kDafitDataHeader) return null;
  final outerLen = (value[1] << 8) | value[2];
  final payloadLen = (value[6] << 8) | value[7];
  if (value.length - 8 < payloadLen || outerLen != 5 + payloadLen) {
    return null;
  }
  return DafitFrame(
    value[3],
    value[5],
    Uint8List.fromList(value.sublist(8, 8 + payloadLen)),
    outerLen,
  );
}

/// Build one outbound data frame.
Uint8List buildDafitFrame(
  int group,
  int command, [
  List<int> payload = const <int>[],
]) {
  final out = Uint8List(8 + payload.length);
  final outerLen = 5 + payload.length;
  out[0] = kDafitDataHeader;
  out[1] = (outerLen >> 8) & 0xff;
  out[2] = outerLen & 0xff;
  out[3] = group & 0xff;
  out[4] = 0x01;
  out[5] = command & 0xff;
  out[6] = (payload.length >> 8) & 0xff;
  out[7] = payload.length & 0xff;
  out.setRange(8, 8 + payload.length, payload);
  return out;
}

/// Build the fixed 8-byte ACK for a received data frame, so a data-bearing
/// exchange keeps moving instead of stalling. Takes the frame being
/// acknowledged directly — its [DafitFrame.outerLen] is the only input, so
/// there is no separate length argument to drift out of sync with it.
Uint8List buildDafitAck(DafitFrame acked) {
  final ackSize = acked.outerLen + 3;
  return Uint8List.fromList(<int>[
    kDafitAckHeader, 0x00, 0x05, //
    acked.group, 0x01,
    (ackSize >> 8) & 0xff, ackSize & 0xff,
    0x01,
  ]);
}

/// True for the fixed 8-byte ACK shape ([kDafitAckHeader]) — the direction
/// this family also uses band-to-app, interspersed with data frames during
/// the same exchange. Not decoded further: nothing downstream needs more
/// than "this notification was an ack, not data".
///
/// Checks every fixed byte the shape actually has ([1], [2], [4] and [7] are
/// all constant — see [buildDafitAck]), not just the header: an 8-byte
/// notification that happens to start with 0xDC but disagrees with the rest
/// of the shape is not an ack, it is something this file does not recognise.
bool isDafitAckFrame(List<int> value) =>
    value.length == 8 &&
    value[0] == kDafitAckHeader &&
    value[1] == 0x00 &&
    value[2] == 0x05 &&
    value[4] == 0x01 &&
    value[7] == 0x01;

/// Pack a local date/time into this family's bit-packed SET_DATE_TIME field:
/// seconds, then (year-2000), month, day, hour, minute each shifted into
/// their own bit range of one big-endian u32.
///
/// `year - 2000` has to fit the field's own six bits (0-63, i.e. 2000-2063).
/// Outside that range the later shift would silently drop the high bits and
/// write a DIFFERENT year to the band's clock — a wrong date it would then
/// act on with total confidence — so this throws instead.
int packDafitDateTime(DateTime t) {
  final yearOffset = t.year - 2000;
  if (yearOffset < 0 || yearOffset > 63) {
    throw ArgumentError.value(t.year, 'year',
        'this family\'s clock field only represents 2000-2063');
  }
  return t.second |
      (yearOffset << 26) |
      (t.month << 22) |
      (t.day << 17) |
      (t.hour << 12) |
      (t.minute << 6);
}

/// Handshake frames, in the order this family expects them. Sending them
/// unconditionally is documented behaviour, not a guess: skipping this
/// sequence is reported to leave later fetches refused and the band's
/// battery draining fast, and each step is a control write, not a request
/// for any physiological data. A caller pauses between writes; timing is a
/// session concern and stays out of this file.
List<Uint8List> dafitInitSequence(DateTime now) => <Uint8List>[
      buildDafitFrame(kDafitGroupGeneral, kDafitCmdInit1, const [0x02]),
      buildDafitFrame(
        kDafitGroupGeneral,
        kDafitCmdSetDateTime,
        (ByteData(4)..setUint32(0, packDafitDateTime(now) & 0xffffffff))
            .buffer
            .asUint8List(),
      ),
      buildDafitFrame(kDafitGroupRequestData, kDafitCmdInit1),
      buildDafitFrame(kDafitGroupRequestData, kDafitCmdInit2),
      buildDafitFrame(
          kDafitGroupGeneral, kDafitCmdSetLanguage, const [kDafitLangEnglish]),
      buildDafitFrame(kDafitGroupGeneral, kDafitCmdInit3, const [kDafitValueOn]),
      buildDafitFrame(kDafitGroupRequestData, kDafitCmdGetHwInfo),
      buildDafitFrame(kDafitGroupBandInfo, kDafitCmdGetBandInfo),
    ];
