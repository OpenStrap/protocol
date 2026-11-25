import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// One 20-byte record: flags, packed UTC time, weight raw, then zeros.
List<int> _rec(int flags, int raw, DateTime t) {
  final packed = t.year |
      (t.month << 13) |
      (t.day << 17) |
      (t.hour << 22) |
      (t.minute << 28) |
      (t.second << 34);
  return [
    flags & 0xff, flags >> 8,
    for (var k = 0; k < 5; k++) (packed >> (8 * k)) & 0xff,
    raw & 0xff, raw >> 8,
    ...List<int>.filled(11, 0),
  ];
}

const _done = 0x0008 | (1 << 9); // weight present, state 1

void main() {
  final t = DateTime.utc(2026, 11, 23, 21, 47, 59);

  test('a finished kg weighing, with its packed UTC stamp', () {
    final r = parseAmazfitScaleRecords(_rec(_done, 14400, t));
    expect(r, hasLength(1));
    expect(r.single.kg, 72.0);
    expect(r.single.at,
        (year: 2026, month: 11, day: 23, hour: 21, minute: 47, second: 59));
  });

  test('units: lb, jin, and stone (raw still pounds)', () {
    double kg(int unitFlags) =>
        parseAmazfitScaleRecords(_rec(_done | unitFlags, 15873, t)).single.kg;
    expect(kg(0x0001), closeTo(158.73 * 0.45359237, 1e-9));
    expect(kg(0x4000), closeTo(79.365, 1e-9));
    expect(kg(0x4001), closeTo(158.73 * 0.45359237, 1e-9));
  });

  test('measuring, failed, no weight, overload: skipped, the rest kept', () {
    final b = [
      ..._rec(0x0008, 14400, t), // still measuring
      ..._rec(0x0008 | (2 << 9), 14400, t), // failed
      ..._rec(1 << 9, 14400, t), // no weight flag
      ..._rec(_done, 0xFFFF, t), // overload
      ..._rec(_done, 16000, t),
      1, 2, 3, // a partial tail
    ];
    expect([for (final r in parseAmazfitScaleRecords(b)) r.kg], [80.0]);
  });

  test('an impossible stamp reads as no stamp, the weight still counts', () {
    final b = _rec(_done, 14400, t)..[2] = 0..[3] = 0;
    final r = parseAmazfitScaleRecords(b).single;
    expect(r.kg, 72.0);
    expect(r.at, isNull);
  });

  test('the clock write is the Mi scales\' Current Time layout', () {
    expect(miScaleClockValue(t), [0xEA, 0x07, 11, 23, 21, 47, 59, 2, 0, 0]);
  });
}
