// The Polar PMD control-point and PPI decoders.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Polar sensor,
// so these fixtures are built from the PMD wire layout, not captured off a
// device. They pin the decode; they do not prove any real sensor behaves
// this way.

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  test('start/stop PPI commands', () {
    expect(polarPmdStartPpi(), [0x02, 0x03]);
    expect(polarPmdStopPpi(), [0x03, 0x03]);
  });

  group('control-point response', () {
    test('a success reply parses', () {
      final r = parsePolarPmdControlResponse([0xF0, 0x02, 0x03, 0x00])!;
      expect(r.reqOpcode, 0x02);
      expect(r.measType, 0x03);
      expect(r.ok, isTrue);
    });

    test('a non-zero status is a refusal, not success', () {
      final r = parsePolarPmdControlResponse([0xF0, 0x02, 0x03, 0x01])!;
      expect(r.ok, isFalse);
    });

    test('missing the 0xF0 marker is not a control-point reply', () {
      expect(parsePolarPmdControlResponse([0x01, 0x02, 0x03, 0x00]), isNull);
    });

    test('truncated replies are dropped', () {
      expect(parsePolarPmdControlResponse([0xF0, 0x02]), isNull);
    });
  });

  group('PPI frames', () {
    List<int> ppiFrame(List<List<int>> records) => [
          0x03, // measurement type, low 6 bits
          ...List.filled(8, 0), // timestamp, unused by this decoder
          0x00, // frame type: not compressed
          for (final r in records) ...r,
        ];

    test('one record decodes', () {
      final samples = parsePolarPmdPpiFrame(ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x00], // hr 60, ppi 1000ms, err 10ms
      ]))!;
      expect(samples, hasLength(1));
      expect(samples.single.hr, 60);
      expect(samples.single.ppiMs, 1000);
      expect(samples.single.errorEstimateMs, 10);
      expect(samples.single.blocker, isFalse);
      expect(samples.single.skinContactBits, 0);
    });

    test('several records in one notification all decode, in order', () {
      final samples = parsePolarPmdPpiFrame(ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x00],
        [61, 0xF0, 0x03, 0x0A, 0x00, 0x00],
      ]))!;
      expect(samples.map((s) => s.hr), [60, 61]);
    });

    test('the blocker bit and the skin-contact bits are read from flags', () {
      // flags 0x07 = blocker (bit0) + both skin-contact bits (bit1, bit2).
      final s = parsePolarPmdPpiFrame(
              ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x07],
      ]))!
          .single;
      expect(s.blocker, isTrue);
      expect(s.skinContactBits, 0x03);
    });

    test('a non-PPI measurement type is not this decoder\'s frame', () {
      final frame = ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x00],
      ]);
      frame[0] = 0x01; // PPG
      expect(parsePolarPmdPpiFrame(frame), isNull);
    });

    test('a compressed frame is refused — PPI is never compressed', () {
      final frame = ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x00],
      ]);
      frame[9] = 0x80;
      expect(parsePolarPmdPpiFrame(frame), isNull);
    });

    test('a non-zero frame type is refused — PPI defines only frame type 0',
        () {
      final frame = ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x00],
      ]);
      frame[9] = 0x01;
      expect(parsePolarPmdPpiFrame(frame), isNull);
    });

    test('a body that is not a whole number of 6-byte records is refused',
        () {
      final frame = ppiFrame([
        [60, 0xE8, 0x03, 0x0A, 0x00, 0x00],
      ])..add(0x00); // one trailing byte
      expect(parsePolarPmdPpiFrame(frame), isNull);
    });

    test('too short to hold a header is refused', () {
      expect(parsePolarPmdPpiFrame([0x03, 0, 0, 0, 0, 0, 0, 0, 0]), isNull);
    });

    test('an empty body is refused', () {
      expect(parsePolarPmdPpiFrame(ppiFrame(const [])), isNull);
    });
  });
}
