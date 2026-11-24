// Edge cases in the huami2021 chunking, fetch bookkeeping and record
// decoders: counter wrap, a lost last chunk, short bodies, 4-byte activity
// rounds, short strides, protobuf bounds, adjacent naps.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('chunks', () {
    test('a message past 256 chunks wraps the counter and still decodes', () {
      final data = List<int>.generate(4000, (i) => i & 0xff);
      final chunks = Huami2021Encoder(mtu: 23).encode(0x0016, data);
      expect(chunks.length, greaterThan(256));
      final dec = Huami2021Decoder();
      Huami2021Frame? frame;
      for (final c in chunks) {
        frame = dec.feed(c) ?? frame;
      }
      expect(frame?.payload, data);
    });

    test('a new first chunk replaces a message whose last chunk was lost', () {
      final enc = Huami2021Encoder(mtu: 23);
      final dec = Huami2021Decoder();
      final lost = enc.encode(0x0016, List<int>.filled(40, 1));
      expect(lost.length, greaterThan(1));
      dec.feed(lost.first); // the rest never arrives
      final next = enc.encode(0x0016, [7, 8, 9]).single;
      expect(dec.feed(next)?.payload, [7, 8, 9]);
    });

    test('a body shorter than its declared length is no frame', () {
      final c = Huami2021Encoder().encode(0x0016, [1, 2, 3, 4]).single;
      final short = Uint8List.fromList(c.sublist(0, c.length - 3));
      expect(Huami2021Decoder().feed(short), isNull);
    });
  });

  group('fetch', () {
    test('an even number of 4-byte activity records matches its count', () {
      expect(huami2021FetchCountMatches(kHuami2021TypeActivity, 6, 24), isTrue);
      expect(huami2021FetchCountMatches(kHuami2021TypeActivity, 3, 24), isTrue);
      expect(huami2021FetchCountMatches(kHuami2021TypeActivity, 6, 20), isFalse);
    });

    test('filler skip follows the announced record count', () {
      expect(huami2021FetchGapSkipMinutes(kHuami2021TypeActivity, 24,
          recordCount: 6), 6);
      expect(huami2021FetchGapSkipMinutes(kHuami2021TypeActivity, 24), 3);
    });
  });

  group('records', () {
    test('a count that does not add up to 4- or 8-byte records gives nothing',
        () {
      final data = Uint8List.fromList([1, 0, 5, 70, 1, 0]);
      expect(parseHuami2021Activity(data, 0, expectedRecordCount: 2), isEmpty);
      // The same bytes with a count that fits still decode.
      final four = Uint8List.fromList([1, 0, 5, 70, 1, 0, 6, 71]);
      expect(parseHuami2021Activity(four, 0, expectedRecordCount: 2),
          isNotEmpty);
    });

    test('a duration field with no value does not borrow the next field', () {
      // prefix, field 2 {1: start}, field 7 {1: <missing>}, then field 16.
      final start = [0x80, 0xA4, 0xA7, 0xDA, 0x06]; // 1,800,000,000
      final data = Uint8List.fromList([
        0, 0,
        0x12, start.length + 1, 0x08, ...start,
        0x3a, 0x01, 0x08,
        0x82, 0x01, 0x02, 0x08, 0x05,
      ]);
      final got = parseHuami2021Workouts(data);
      expect(got.where((w) => w.durationSec == 130), isEmpty);
    });

    test('a trailing fixed64 with no value bytes drops that workout', () {
      final start = [0x80, 0xA4, 0xA7, 0xDA, 0x06];
      final data = Uint8List.fromList([
        0, 0,
        0x12, start.length + 1, 0x08, ...start,
        0x09, 1, 2, // fixed64 tag, 2 of its 8 bytes
      ]);
      expect(parseHuami2021Workouts(data), isEmpty);
    });

    test('a stage starting at one nap\'s end goes to the next nap only', () {
      final b = Uint8List(594);
      final bd = ByteData.sublistView(b);
      bd.setUint32(0, 1800000000, Endian.little);
      bd.setUint32(4, 1800000000, Endian.little);
      b[8] = 1;
      b[9] = 1;
      void nap(int i, int s, int e) {
        bd.setUint16(0x018 + i * 6, s, Endian.little);
        bd.setUint16(0x018 + i * 6 + 2, e, Endian.little);
        bd.setUint16(0x018 + i * 6 + 4, e - s, Endian.little);
      }

      void stage(int i, int s, int e, int type) {
        bd.setUint16(0x155 + i * 5, s, Endian.little);
        bd.setUint16(0x155 + i * 5 + 2, e, Endian.little);
        b[0x155 + i * 5 + 4] = type;
      }

      nap(0, 600, 630);
      nap(1, 630, 660);
      stage(0, 600, 630, kHuami2021StageLight);
      stage(1, 630, 660, kHuami2021StageDeep);
      final naps = parseHuami2021Sleep(b).where((s) => s.isNap).toList();
      expect(naps, hasLength(2));
      expect((naps[0].lightMin, naps[0].deepMin), (30, 0));
      expect((naps[1].lightMin, naps[1].deepMin), (0, 30));
    });
  });
}
