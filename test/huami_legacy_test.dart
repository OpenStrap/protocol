import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('clock value: Sunday is 0, ms/4, then the UTC offset in quarters', () {
    final t = DateTime(2026, 10, 4, 7, 5, 9, 500); // a Sunday
    final v = huamiTimeValue(t);
    expect(v.sublist(0, 9), [0xea, 0x07, 10, 4, 7, 5, 9, 0, 125]);
    expect(v[9], anyOf(0, 8));
    expect(v.last, (t.timeZoneOffset.inMinutes ~/ 15) & 0xff);
    expect(huamiTimeValue(DateTime(2026, 10, 10))[7], 6, reason: 'Saturday');
  });

  test('fetch start: type 1, minute-resolution since, 0, tz', () {
    final v = huamiActivityFetchStart(DateTime(2026, 10, 3, 0, 0));
    expect(v.sublist(0, 9), [0x01, 0x01, 0xea, 0x07, 10, 3, 0, 0, 0]);
    expect(v, hasLength(10));
  });

  test('start response: sample count and an absolute start instant', () {
    // 2026-10-03 00:00 at UTC+05:30 (22 quarters) = 2026-10-02 18:30Z.
    final r = parseHuamiFetchStart(
        [0x10, 0x01, 0x01, 0x40, 0x16, 0, 0, 0xea, 0x07, 10, 3, 0, 0, 0, 22])!;
    expect(r.count, 0x1640);
    expect(r.startSec,
        DateTime.utc(2026, 10, 2, 18, 30).millisecondsSinceEpoch ~/ 1000);
    expect(parseHuamiFetchStart([0x10, 0x01, 0x01, 0, 0, 0, 0])!.count, 0);
    // More than 90 days of minutes is not a real answer.
    expect(
        parseHuamiFetchStart(
            [0x10, 0x01, 0x01, 0x41, 0xfa, 0x01, 0, 0xea, 0x07, 10, 3, 0, 0, 0, 0]),
        isNull);
    expect(parseHuamiFetchStart([0x10, 0x01, 0x02]), isNull);
  });

  test('samples: kind inheritance, no-reading HR, minute timestamps', () {
    final buf = HuamiActivityBuffer()
      ..add([0, 0x09, 10, 0, 55, 0x00, 5, 0, 0xff])
      ..add([1, 0x5b, 3, 0, 52]); // high nibble masked off: kind 11
    expect(buf.ok, isTrue);
    final m = buf.minutes(1000);
    expect(m.map((x) => (x.tsSec, x.kind, x.hr)),
        [(1000, 9, 55), (1060, 9, null), (1120, 11, 52)]);
    expect(m.every((x) => x.asleep), isTrue);
  });

  test('a counter gap marks the transfer untrustworthy', () {
    final buf = HuamiActivityBuffer()..add([0, 1, 0, 0, 0])..add([2, 1, 0, 0, 0]);
    expect(buf.ok, isFalse);
    expect(huamiFetchDone([0x10, 0x02, 0x01]), isTrue);
  });

  test('an exact repeat of the previous packet is dropped, not a gap', () {
    final buf = HuamiActivityBuffer()
      ..add([0, 1, 2, 3, 4])
      ..add([0, 1, 2, 3, 4])
      ..add([1, 5, 6, 7, 8]);
    expect(buf.ok, isTrue);
    expect(buf.bytes, [1, 2, 3, 4, 5, 6, 7, 8]);
    // Same counter, different bytes: a real gap.
    final bad = HuamiActivityBuffer()..add([0, 1, 2, 3, 4])..add([0, 9, 9, 9, 9]);
    expect(bad.ok, isFalse);
  });
}
