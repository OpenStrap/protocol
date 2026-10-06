import 'dart:typed_data';

import 'package:openstrap_protocol/src/garmin_fit.dart';
import 'package:test/test.dart';

/// A tiny FIT writer for tests: definitions + data records, little-endian.
class FitWriter {
  final _recs = <int>[];

  void define(int local, int global, List<(int field, int size, int base)> f,
      {bool bigEndian = false}) {
    _recs.addAll([0x40 | local, 0, bigEndian ? 1 : 0]);
    _recs.addAll(bigEndian ? [global >> 8, global & 0xff] : [global & 0xff, global >> 8]);
    _recs.add(f.length);
    for (final (n, s, b) in f) {
      _recs.addAll([n, s, b]);
    }
  }

  void data(int local, List<int> bytes) => _recs.addAll([local, ...bytes]);
  void compressed(int local, int offset, List<int> bytes) =>
      _recs.addAll([0x80 | (local << 5) | (offset & 0x1f), ...bytes]);

  List<int> build() {
    final n = _recs.length;
    return [
      12, 0x20, 0x08, 0x08, n & 0xff, (n >> 8) & 0xff, 0, 0,
      ...'.FIT'.codeUnits, ..._recs, 0, 0,
    ];
  }
}

List<int> u16(int v) => [v & 0xff, v >> 8];
List<int> u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24];
int fitTs(int unix) => unix - kFitEpochOffset;

void main() {
  final t0 = DateTime(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000;

  test('rejects what is not FIT', () {
    expect(() => parseFit([1, 2, 3]), throwsFormatException);
    expect(() => parseFit([12, 0, 0, 0, 99, 0, 0, 0, ...'.FIT'.codeUnits]),
        throwsFormatException);
  });

  test('monitoring: full timestamp, then timestamp_16, HR and steps', () {
    final w = FitWriter()
      ..define(0, kFitMsgMonitoring, [(253, 4, 0x86), (5, 1, 0), (3, 4, 0x86), (27, 1, 2)])
      ..data(0, [...u32(fitTs(t0)), 6, ...u32(100), 62])
      ..define(1, kFitMsgMonitoring, [(26, 2, 0x84), (5, 1, 0), (3, 4, 0x86), (27, 1, 2)])
      ..data(1, [...u16((fitTs(t0) + 60) & 0xffff), 6, ...u32(250), 70])
      ..data(1, [...u16((fitTs(t0) + 120) & 0xffff), 1, ...u32(40), 0xff]);
    final m = parseFit(w.build());
    expect(fitMonitoringHr(m), [(t0, 62), (t0 + 60, 70)]);
    expect(fitDailySteps(m), {DateTime(2026, 10, 4): 290});
  });

  test('steps: activity type falls back to the low bits of field 24', () {
    final w = FitWriter()
      ..define(0, kFitMsgMonitoring, [(253, 4, 0x86), (3, 4, 0x86), (24, 1, 0x0d)])
      ..data(0, [...u32(fitTs(t0)), ...u32(321), 0x66]);
    expect(fitDailySteps(parseFit(w.build())), {DateTime(2026, 10, 4): 321});
  });

  test('compressed timestamps roll over every 32 s', () {
    final base = fitTs(t0) & ~0x1f; // aligned
    final w = FitWriter()
      ..define(0, kFitMsgMonitoring, [(253, 4, 0x86), (27, 1, 2)])
      ..data(0, [...u32(base + 30), 60])
      ..define(1, kFitMsgMonitoring, [(27, 1, 2)])
      ..compressed(1, 2, [61]); // offset 2 < 30 -> next 32-s window
    final hr = fitMonitoringHr(parseFit(w.build()));
    expect(hr.last.$1, base + 34 + kFitEpochOffset);
  });

  test('sleep levels become stage spans; invalid values are absent', () {
    final w = FitWriter()..define(0, kFitMsgSleepLevel, [(253, 4, 0x86), (0, 1, 0)]);
    for (final (min, level) in [(0, 2), (30, 3), (90, 4), (120, 1), (125, 0xff)]) {
      w.data(0, [...u32(fitTs(t0) + min * 60), level]);
    }
    expect(fitSleepStages(parseFit(w.build())), [
      (t0, t0 + 1800, 'light'),
      (t0 + 1800, t0 + 5400, 'deep'),
      (t0 + 5400, t0 + 7200, 'rem'),
      (t0 + 7200, t0 + 7500, 'wake'),
    ]);
  });

  test('HRV summary, resting HR, SpO2, respiration, big-endian definitions',
      () {
    final w = FitWriter()
      ..define(0, kFitMsgHrvStatusSummary, [(253, 4, 0x86), (1, 2, 0x84)])
      ..data(0, [...u32(fitTs(t0)), ...u16(48 * 128)])
      ..define(1, kFitMsgMonitoringHrData, [(253, 4, 0x86), (1, 1, 2)])
      ..data(1, [...u32(fitTs(t0)), 51])
      ..define(2, kFitMsgSpo2Data, [(253, 4, 0x86), (0, 1, 2)], bigEndian: true)
      ..data(2, [...u32(fitTs(t0)).reversed, 96])
      ..define(3, kFitMsgRespirationRate, [(253, 4, 0x86), (0, 2, 0x83)])
      ..data(3, [...u32(fitTs(t0)), ...u16(1350)]);
    final m = parseFit(w.build());
    expect(fitHrvLastNight(m), [(t0, 48.0)]);
    expect(fitRestingHr(m), [(t0, 51)]);
    expect(fitSpo2(m), [(t0, 96)]);
    expect(fitRespiration(m), [(t0, 13.5)]);
  });

  test('a record that overruns the data is refused, not half-read', () {
    final good = (FitWriter()
          ..define(0, kFitMsgMonitoring, [(253, 4, 0x86)])
          ..data(0, u32(1)))
        .build();
    final bad = Uint8List.fromList(good)..[4] = good[4] - 2;
    expect(() => parseFit(bad), throwsFormatException);
  });
}
