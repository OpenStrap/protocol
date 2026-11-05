// realtime96.dart — the unframed 96-byte realtime sensor packet that the
// WHOOP 4 data-stream characteristic delivers as raw BLE notifications
// (unlike the framed 0xAA… packets, which go through framing.dart).
//
// Layout (community reverse engineering; HR/RR framing cross-checked against
// multiple independent sources, SpO2/temperature single-source and NOT
// validated against a reference device):
//   [0]    u8    sequence / packet type
//   [1:3]  u16LE heart rate * 100
//   [3:5]  u16LE RR interval ms
//   [5]    u8    SpO2 byte — RAW ONLY, see [Realtime96.spo2Raw]
//   [6]    u8    skin temperature byte (offset +25 C claimed, unconfirmed)
//   [7:92]      candidate accel/PPG/ambient fields, meaning unconfirmed
//   [92:96] u32LE CRC-32 over bytes [0:92), see [crc32WhoopStream]
//
// PURE Dart — dart:typed_data only. No I/O, no dependencies.

import 'dart:typed_data';

/// Expected length of one realtime sensor packet, in bytes.
const int kRealtime96PacketSize = 96;

/// CRC-32 over the first 92 bytes of a realtime packet.
///
/// Reflected CRC-32 (poly 0x04C11DB7, init 0xFFFFFFFF) with xor-out
/// 0xF43F44AC — TWO independent community sources agree on this xor-out, and
/// it is deliberately NOT the same as the framed-packet [crc32] in crc.dart
/// (zlib xor-out 0xFFFFFFFF): the unframed data stream uses its own trailer
/// checksum, so the two must not be mixed.
int crc32WhoopStream(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crc32Table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xF43F44AC) & 0xFFFFFFFF;
}

final Uint32List _crc32Table = _makeTable();

Uint32List _makeTable() {
  final table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c;
  }
  return table;
}

/// One decoded 96-byte realtime packet. Every field is RAW — this package
/// publishes no calibrated unit from this packet, including no SpO2 percent.
class Realtime96 {
  /// Packet type / sequence counter, byte [0].
  final int sequence;

  /// Heart-rate field as delivered: bpm * 100, u16 LE at [1:3]. Raw, so a
  /// mis-framed packet cannot masquerade as a plausible bpm.
  final int hrTimes100;

  /// RR-interval field as delivered, u16 LE at [3:5], ms. Raw for the same
  /// reason.
  final int rrMsRaw;

  /// Byte [5] — community-reported SpO2 byte.
  ///
  /// RAW AND UNVALIDATED: the only evidence is single-source community
  /// reverse engineering with a 50–100 range gate, and the original
  /// reverse-engineering write-up says blood oxygen on this band is measured
  /// only during sleep. The byte is exposed exactly as received so captures
  /// can be correlated against a reference oximeter; it must NOT be
  /// published to a user as a percentage.
  final int spo2Raw;

  /// Byte [6] — skin-temperature byte, raw. The +25 C offset is claimed but
  /// unconfirmed, so no Celsius getter exists.
  final int skinTempRaw;

  /// Whether the trailing CRC-32 matched bytes [0:92]. A packet with
  /// [crcValid] == false is mis-framed or corrupted: its fields are still
  /// the bytes that arrived, but nothing downstream should trust them.
  final bool crcValid;

  const Realtime96({
    required this.sequence,
    required this.hrTimes100,
    required this.rrMsRaw,
    required this.spo2Raw,
    required this.skinTempRaw,
    required this.crcValid,
  });
}

/// Decode one 96-byte realtime packet, or null when [bytes] is not exactly
/// [kRealtime96PacketSize] long (a short notification is a fragment, never a
/// shorter packet).
Realtime96? parseRealtime96(List<int> bytes) {
  if (bytes.length != kRealtime96PacketSize) return null;
  final view = ByteData.sublistView(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  final crcReceived = view.getUint32(92, Endian.little);
  return Realtime96(
    sequence: bytes[0],
    hrTimes100: view.getUint16(1, Endian.little),
    rrMsRaw: view.getUint16(3, Endian.little),
    spo2Raw: bytes[5],
    skinTempRaw: bytes[6],
    crcValid: crc32WhoopStream(bytes.sublist(0, 92)) == crcReceived,
  );
}
