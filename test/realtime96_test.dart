// Tests for the unframed 96-byte realtime packet decoder. The packets are
// synthetic — built from the community-documented layout with the CRC
// computed by the same crc32WhoopStream the decoder verifies — because no
// real capture of this stream is in the repo; the CRC xor-out (0xF43F44AC) is
// itself only community-sourced, so these tests pin the ARITHMETIC, not the
// wire fact.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Build a 96-byte packet with a valid trailer CRC.
Uint8List buildPacket({
  int sequence = 1,
  int hrTimes100 = 6200,
  int rrMs = 968,
  int spo2 = 97,
  int skinTemp = 62,
}) {
  final b = Uint8List(kRealtime96PacketSize);
  b[0] = sequence;
  final v = ByteData.sublistView(b);
  v.setUint16(1, hrTimes100, Endian.little);
  v.setUint16(3, rrMs, Endian.little);
  b[5] = spo2;
  b[6] = skinTemp;
  v.setUint32(92, crc32WhoopStream(b.sublist(0, 92)), Endian.little);
  return b;
}

void main() {
  group('parseRealtime96', () {
    test('decodes all raw fields and validates the CRC', () {
      final p = parseRealtime96(buildPacket())!;
      expect(p.sequence, 1);
      expect(p.hrTimes100, 6200);
      expect(p.rrMsRaw, 968);
      expect(p.spo2Raw, 97);
      expect(p.skinTempRaw, 62);
      expect(p.crcValid, isTrue);
    });

    test('rejects any length other than 96 — a fragment is not a packet', () {
      expect(parseRealtime96(buildPacket().sublist(0, 95)), isNull);
      final long = Uint8List(97);
      expect(parseRealtime96(long), isNull);
      expect(parseRealtime96(const []), isNull);
    });

    test('a corrupted payload byte fails the CRC but fields stay raw', () {
      final b = buildPacket();
      b[5] = 42; // flip the spo2 byte AFTER the CRC was computed
      final p = parseRealtime96(b)!;
      expect(p.crcValid, isFalse);
      expect(p.spo2Raw, 42);
    });

    test('spo2Raw is passthrough: even an out-of-range byte is exposed raw, never gated into a %', () {
      final p = parseRealtime96(buildPacket(spo2: 0xFF))!;
      expect(p.spo2Raw, 0xFF);
      expect(p.crcValid, isTrue);
    });

    test('crc32WhoopStream differs from the framed-packet crc32 (different xor-out)', () {
      final body = List<int>.generate(92, (i) => i);
      expect(crc32WhoopStream(body), isNot(crc32(body)));
      // Known-answer vector, computed independently of the implementation:
      // standard CRC-32 of "123456789" is 0xCBF43926; with this stream's
      // xor-out 0xF43F44AC it becomes 0xC0348275.
      expect(crc32WhoopStream('123456789'.codeUnits), 0xC0348275);
    });
  });
}
