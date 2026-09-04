import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('DaFit / MOYOUNG-V2 framing', () {
    test('parses a real captured SET_DATE_TIME data frame', () {
      // 0xCD 0x00 0x09 0x12 0x01 0x01 0x00 0x04 0xA5 0x83 0x73 0xDB
      final f = parseDafitFrame(
          [0xcd, 0x00, 0x09, 0x12, 0x01, 0x01, 0x00, 0x04, 0xa5, 0x83, 0x73, 0xdb]);
      expect(f, isNotNull);
      expect(f!.group, 0x12);
      expect(f.command, 0x01);
      expect(f.outerLen, 0x09);
      expect(f.payload, [0xa5, 0x83, 0x73, 0xdb]);
    });

    test('rejects an ACK-headed frame as a data frame', () {
      // dc 00 05 1a 01 00 0c 01
      expect(parseDafitFrame([0xdc, 0x00, 0x05, 0x1a, 0x01, 0x00, 0x0c, 0x01]),
          isNull);
    });

    test('rejects a truncated payload', () {
      expect(parseDafitFrame([0xcd, 0x00, 0x09, 0x12, 0x01, 0x01, 0x00, 0x04, 0xa5]),
          isNull);
    });

    test('rejects an outer length that disagrees with the payload length',
        () {
      // Same bytes as the real captured frame above, but the outer length
      // (byte 2) claims 8 instead of the correct 9 — a malformed frame, not
      // a shorter one, since the payload bytes and their own length field
      // still say 4.
      expect(
          parseDafitFrame(
              [0xcd, 0x00, 0x08, 0x12, 0x01, 0x01, 0x00, 0x04, 0xa5, 0x83, 0x73, 0xdb]),
          isNull);
    });

    test('isDafitAckFrame identifies only the fixed 8-byte ack shape', () {
      expect(isDafitAckFrame([0xdc, 0x00, 0x05, 0x1a, 0x01, 0x00, 0x0c, 0x01]),
          isTrue);
      expect(
          isDafitAckFrame(
              [0xcd, 0x00, 0x09, 0x12, 0x01, 0x01, 0x00, 0x04, 0xa5, 0x83, 0x73, 0xdb]),
          isFalse);
    });

    test('buildDafitFrame round-trips through parseDafitFrame', () {
      final built = buildDafitFrame(0x12, 0x0a, const [0x02]);
      expect(built, [0xcd, 0x00, 0x06, 0x12, 0x01, 0x0a, 0x00, 0x01, 0x02]);
      final parsed = parseDafitFrame(built);
      expect(parsed!.group, 0x12);
      expect(parsed.command, 0x0a);
      expect(parsed.payload, [0x02]);
    });

    test('buildDafitFrame with no payload', () {
      final built = buildDafitFrame(0x1a, 0x0a);
      expect(built, [0xcd, 0x00, 0x05, 0x1a, 0x01, 0x0a, 0x00, 0x00]);
    });

    test('buildDafitAck echoes the acked frame\'s own outer length', () {
      final acked = parseDafitFrame([0xcd, 0x00, 0x05, 0x1a, 0x01, 0x0a, 0x00, 0x00])!;
      final ack = buildDafitAck(acked);
      expect(ack, [0xdc, 0x00, 0x05, 0x1a, 0x01, 0x00, 0x08, 0x01]);
    });

    test('packDafitDateTime packs fields into the documented bit ranges', () {
      final t = DateTime(2024, 3, 5, 14, 22, 37);
      final v = packDafitDateTime(t);
      expect(v & 0x3f, 37); // seconds, bits 0-5
      expect((v >> 6) & 0x3f, 22); // minute
      expect((v >> 12) & 0x1f, 14); // hour
      expect((v >> 17) & 0x1f, 5); // day
      expect((v >> 22) & 0xf, 3); // month
      expect((v >> 26) & 0x3f, 24); // year - 2000
    });

    test('packDafitDateTime refuses a year outside 2000-2063', () {
      expect(() => packDafitDateTime(DateTime(1999, 1, 1)),
          throwsArgumentError);
      expect(() => packDafitDateTime(DateTime(2064, 1, 1)),
          throwsArgumentError);
      // The boundary itself is fine.
      expect(() => packDafitDateTime(DateTime(2063, 1, 1)), returnsNormally);
    });

    test('dafitInitSequence is eight well-formed, parseable frames', () {
      final seq = dafitInitSequence(DateTime(2024, 3, 5, 14, 22, 37));
      expect(seq, hasLength(8));
      for (final frame in seq) {
        expect(frame[0], kDafitDataHeader);
        expect(parseDafitFrame(frame), isNotNull);
      }
      // The clock write really carries the packed value from above.
      final clockFrame = parseDafitFrame(seq[1])!;
      expect(clockFrame.group, kDafitGroupGeneral);
      expect(clockFrame.command, kDafitCmdSetDateTime);
      expect(clockFrame.payload.length, 4);
    });
  });
}
