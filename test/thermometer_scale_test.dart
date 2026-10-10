import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// IEEE-11073 FLOAT bytes for mantissa * 10^exp.
List<int> f32(int mantissa, int exp) {
  final m = mantissa & 0xffffff;
  return [m & 0xff, (m >> 8) & 0xff, (m >> 16) & 0xff, exp & 0xff];
}

List<int> dt(int y, int mo, int d, int h, int mi, int s) =>
    [y & 0xff, y >> 8, mo, d, h, mi, s];

void main() {
  group('IEEE-11073 FLOAT', () {
    test('mantissa x 10^exponent, signed both ways', () {
      expect(ieee11073Float32(f32(3652, -2), 0), closeTo(36.52, 1e-9));
      expect(ieee11073Float32(f32(-5, 1), 0), -50);
    });
    test('reserved values are not numbers', () {
      expect(ieee11073Float32(f32(0x7fffff, 0), 0), isNull); // NaN
      expect(ieee11073Float32(f32(0x800000, 0), 0), isNull); // NRes
    });
  });

  group('health thermometer', () {
    test('Celsius with timestamp and site', () {
      final m = parseHtpMeasurement(
          [0x06, ...f32(3652, -2), ...dt(2026, 10, 4, 6, 41, 3), 0x02])!;
      expect(m.celsius, closeTo(36.52, 1e-9));
      expect(m.at, (year: 2026, month: 10, day: 4, hour: 6, minute: 41,
          second: 3));
      expect(m.site, 2);
    });
    test('Fahrenheit is converted, no timestamp is null', () {
      final m = parseHtpMeasurement([0x01, ...f32(9770, -2)])!;
      expect(m.celsius, closeTo(36.5, 1e-9));
      expect(m.at, isNull);
    });
    test('malformed or reserved values decode to nothing', () {
      expect(parseHtpMeasurement([0x00, 1, 2]), isNull);
      expect(parseHtpMeasurement([0x00, ...f32(0x7fffff, 0)]), isNull);
    });
    test('a declared field the value does not carry refuses it', () {
      // Timestamp flagged, only 4 of its 7 bytes present.
      expect(
          parseHtpMeasurement(
              [0x02, ...f32(3652, -2), ...dt(2026, 10, 4, 6, 41, 3).take(4)]),
          isNull);
      // Site flagged, no site byte.
      expect(parseHtpMeasurement([0x04, ...f32(3652, -2)]), isNull);
    });
    test('a day the month does not have is not a date', () {
      expect(gattDateTime(dt(2026, 2, 31, 6, 0, 0), 0), isNull);
      expect(gattDateTime(dt(2025, 2, 29, 6, 0, 0), 0), isNull);
      expect(gattDateTime(dt(2024, 2, 29, 6, 0, 0), 0)?.day, 29);
      expect(gattDateTime(dt(10000, 1, 1, 0, 0, 0), 0), isNull);
    });
    test('current time value', () {
      final v = currentTimeValue(DateTime(2026, 10, 4, 7, 5, 9, 500));
      expect(v, [0xea, 0x07, 10, 4, 7, 5, 9, DateTime.sunday, 128, 0]);
    });
  });

  group('Mi scales', () {
    List<int> bc(int f0, int f1, int ohm, int raw) => [
          f0, f1, ...dt(2026, 10, 4, 7, 30, 0), ohm & 0xff, ohm >> 8, //
          raw & 0xff, raw >> 8,
        ];
    List<int> rec(int flags, int raw) =>
        [flags, raw & 0xff, raw >> 8, ...dt(2026, 10, 3, 21, 0, 0)];

    test('body composition: kg, impedance, timestamp when stabilised', () {
      final r = parseMiBodyComposition(bc(0x02, 0x22, 500, 14368))!;
      expect(r.kg, closeTo(71.84, 1e-9)); // 14368 / 200
      expect(r.impedanceOhm, 500);
      expect(r.at!.hour, 7);
    });
    test('body composition: settling is ignored, a finished frame is kept', () {
      expect(parseMiBodyComposition(bc(0x02, 0x02, 0, 14368)), isNull);
      expect(parseMiBodyComposition(bc(0x02, 0xa2, 500, 14368))!.kg,
          closeTo(71.84, 1e-9));
    });
    test('body composition: pounds from byte 0, jin from byte 1 bit 6', () {
      expect(parseMiBodyComposition(bc(0x01, 0x20, 0, 15800))!.kg,
          closeTo(71.67, 0.01));
      expect(parseMiBodyComposition(bc(0x00, 0x60, 0, 14368))!.kg,
          closeTo(71.84, 1e-9));
      // Byte 1 bit 0 is not a unit: still raw / 200 kg.
      expect(parseMiBodyComposition(bc(0x00, 0x21, 0, 14368))!.kg,
          closeTo(71.84, 1e-9));
    });
    test('body composition: impedance only when stable and real', () {
      expect(parseMiBodyComposition(bc(0, 0x20, 500, 14368))!.impedanceOhm,
          isNull);
      expect(parseMiBodyComposition(bc(0, 0x22, 65534, 14368))!.impedanceOhm,
          isNull);
      expect(parseMiBodyComposition(bc(0, 0x22, 65533, 14368))!.impedanceOhm,
          isNull);
    });
    test('overload is not a weight', () {
      expect(parseMiBodyComposition(bc(0x01, 0x22, 0, 0xFFF0)), isNull);
      expect(parseMiScale2Records(rec(0x21, 0xFFF0)), isEmpty);
      expect(parseMiScale2History(rec(0x21, 0xFFF0)), isEmpty);
    });
    test('body composition history: every 13-byte record, no stability '
        'filter; a zero weight is skipped', () {
      final r = parseMiBodyCompositionRecords([
        ...bc(0, 0x22, 500, 14368),
        ...bc(0, 0x02, 0, 14000),
        ...bc(0, 0x20, 0, 0),
        ...bc(0, 0x20, 0, 14400),
      ]);
      expect(r.map((x) => x.kg), [71.84, 70.0, 72.0]);
      expect(r.first.impedanceOhm, 500);
    });
    test('scale 2: packed 10-byte records, lb, jin and stone', () {
      final r = parseMiScale2Records([...rec(0x20, 14368), ...rec(0x21, 15800)]);
      expect(r.map((x) => x.kg.toStringAsFixed(2)), ['71.84', '71.67']);
      expect(parseMiScale2Records(rec(0x30, 14368)).single.kg, 71.84);
      expect(parseMiScale2Records(rec(0x31, 1100)).single.kg,
          closeTo(69.85, 0.01));
    });
    test('scale 2 live: an unstable record skips itself, not the rest', () {
      final r = parseMiScale2Records(
          [...rec(0x00, 1), ...rec(0xa0, 14000), ...rec(0x20, 14368)]);
      expect(r.single.kg, 71.84);
    });
    test('scale 2 history: no stability filter; empty, zero and overload '
        'records are skipped', () {
      final r = parseMiScale2History([
        ...rec(0xa2, 14000),
        ...rec(0x00, 14000),
        ...rec(0x62, 14200),
        ...rec(0x22, 0),
        ...rec(0x02, 14368),
      ]);
      expect(r.map((x) => x.kg), [70.0, 71.0, 71.84]);
    });
    test('history request is little-endian; count, stop and end marker', () {
      expect(miScaleHistoryRequest(1), [1, 1, 0, 0, 0]);
      expect(miScaleHistoryRequest(0x01020304), [1, 4, 3, 2, 1]);
      expect(miScaleHistoryCount([0x01, 0x02, 0x01]), 258);
      expect(miScaleHistoryCount([0x01, 0x02]), isNull);
      expect(miScaleHistoryDone([0x03]), isTrue);
      expect(miScaleHistoryDone([]), isTrue);
      expect(miScaleHistoryDone([0x03, 0]), isFalse);
      expect(kMiScaleHistoryStop, [0x03]);
    });
    test('user mode command per scale', () {
      expect(miScaleUserModeCommand(composition: true), [6, 11, 0, 0]);
      expect(miScaleUserModeCommand(composition: false), [3, 1, 0, 0, 0]);
    });
    test('clock: UTC components, Sunday = 1, two zero bytes', () {
      expect(miScaleClockValue(DateTime.utc(2026, 10, 4, 7, 5, 9, 500)),
          [0xea, 0x07, 10, 4, 7, 5, 9, 1, 0, 0]);
      expect(miScaleClockValue(DateTime.utc(2026, 10, 10))[7], 7);
    });
  });
}
