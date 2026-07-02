import 'dart:math' as math;

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

    test('parseR24 auto-routes v25 and decodes unix + gravity', () {
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
        final mag = math.sqrt(
          r.accelG[0] * r.accelG[0] +
              r.accelG[1] * r.accelG[1] +
              r.accelG[2] * r.accelG[2],
        );
        expect(mag, inInclusiveRange(0.8, 1.2));
      }
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
