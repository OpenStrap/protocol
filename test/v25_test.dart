import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

String _innerHex(String framed) => framed.substring(8);

void main() {
  group('WHOOP 4 historical v25 auto-routing', () {
    final records = [
      'aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716',
      'aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf',
      'aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9',
    ];

    test('parseR24 auto-routes v25 and decodes the unix second only', () {
      final parsed = [
        for (final hex in records) parseR24(hexToBytes(_innerHex(hex)))
      ];
      expect(parsed.every((r) => r != null), isTrue);
      final rows = parsed.cast<R24>();
      expect(rows.map((r) => r.histVersion).toSet(), {25});
      expect(rows[0].tsEpoch, greaterThan(1781000000));
      expect(rows[1].tsEpoch, rows[0].tsEpoch + 1);
      expect(rows[2].tsEpoch, rows[0].tsEpoch + 2);
      for (final r in rows) {
        expect(r.hr, 0);
        expect(r.rrIntervalsMs, isEmpty);
        expect(r.spo2RedRaw, 0);
        expect(r.spo2IrRaw, 0);
        // No accel on v25. The old inner[69/71/73] read looked like a ~1 g
        // vector on exactly these records, which is why it survived so long:
        // across the real corpus its "z" has three distinct values, its "x" is
        // half an f32, and it correlates 0.16/0.22/0.06 with the v24 gravity
        // for the same second. Absent, NOT (0,0,0) — a zero vector is a still
        // wrist to every motion consumer.
        expect(r.accelG, isEmpty);
      }
    });

    test('the waveform payload and its timestamp are untouched', () {
      final r = parseR24(hexToBytes(_innerHex(records[0])))!;
      // rawTail is inner[13:], i.e. the PPG burst itself. Compare the WHOLE
      // slice, not `endsWith` — that also passes if the decoder silently drops
      // leading waveform bytes, which is the failure worth catching.
      expect(r.rawTail, isNotEmpty);
      expect(r.rawTail, _innerHex(records[0]).substring(13 * 2));
    });

    test('v25 carries the v24 sub-second field at inner[11:13]', () {
      final rows = [
        for (final hex in records) parseR24(hexToBytes(_innerHex(hex)))!
      ];
      expect(rows.map((r) => r.tsSubsec).toList(), [17184, 15912, 14648]);
      // One record every ~0.961 s: each +1 s step of the unix second comes
      // with the sub-second count falling by ~1270/32768 s.
      double t(R24 r) => r.tsEpoch + r.tsSubsec / 32768;
      expect(t(rows[1]) - t(rows[0]), closeTo(0.9612, 0.001));
      expect(t(rows[2]) - t(rows[1]), closeTo(0.9614, 0.001));
    });

    test('reconstructV25Samples: i32 first sample + 24 i16 deltas -> 25 samples', () {
      // Expected values computed independently (Python, struct.unpack) from
      // the same hex.
      final s0 = reconstructV25Samples(hexToBytes(_innerHex(records[0])))!.samples;
      expect(s0.length, 25);
      expect(s0.take(4).toList(), [209219, 209857, 210470, 211168]);
      expect(s0.last, 235637);
      final s1 = reconstructV25Samples(hexToBytes(_innerHex(records[1])))!.samples;
      expect([s1.first, s1[1], s1[2], s1[3], s1.last],
          [241056, 244762, 246434, 246842, 231647]);
      final s2 = reconstructV25Samples(hexToBytes(_innerHex(records[2])))!.samples;
      expect([s2.first, s2.last], [233842, 285571]);
    });

    test('no rail delta: re-encoding gives the original bytes', () {
      for (final hex in records) {
        final inner = hexToBytes(_innerHex(hex));
        final r = reconstructV25Samples(inner)!;
        expect(r.hasSaturatedDelta, isFalse);
        final s = r.samples;
        final out = ByteData(48 + 4);
        out.setInt32(0, s[0], Endian.little);
        for (var k = 0; k < 24; k++) {
          out.setInt16(4 + 2 * k, s[k + 1] - s[k], Endian.little);
        }
        expect(out.buffer.asUint8List(), inner.sublist(15, 67));
      }
    });

    test('reconstructV25Samples rejects non-v25 and truncated records', () {
      final inner = hexToBytes(_innerHex(records[0]));
      expect(reconstructV25Samples(inner.sublist(0, 66)), isNull);
      final v24 = Uint8List.fromList(inner)..[1] = 24;
      expect(reconstructV25Samples(v24), isNull);
    });

    test('a rail delta marks that sample and the rest as ambiguous', () {
      final inner = hexToBytes(_innerHex(records[0]));
      ByteData.sublistView(inner).setInt16(19 + 2 * 5, 32767, Endian.little);
      final r = reconstructV25Samples(inner)!;
      expect(r.firstAmbiguousSampleIndex, 6);
      expect(r.trustedSamples.length, 6);
    });

    test('decodeRecord surfaces v25 timestamps', () {
      final decoded = [for (final hex in records) decodeRecord(_innerHex(hex))];
      expect(decoded.every((r) => r != null), isTrue);
      expect(decoded[0]!.recType, 25);
      expect(decoded[0]!.ts, greaterThan(1781000000));
      expect(decoded[1]!.ts, decoded[0]!.ts + 1);
      expect(decoded[2]!.ts, decoded[0]!.ts + 2);
    });
  });
}
