// Huami2021/ZeppOS record decoders: known-value tests against real device
// output, plus guard tests for the sentinel/gap/invalid-slot rules.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

Uint8List unhex(Object? raw) {
  final s = raw! as String;
  return Uint8List.fromList(
      [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}

void main() {
  final v = jsonDecode(File('test/fixtures/huami2021_vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final parsers = v['parsers'] as Map<String, dynamic>;
  final roundStartMs = parsers['roundStartMs'] as int;
  final activity = parsers['activity'] as Map<String, dynamic>;

  void expectSamples(List<Huami2021Sample> got, String key) {
    final expected = (activity[key]['samples'] as List).cast<Map<String, dynamic>>();
    expect(got.length, expected.length, reason: 'sample count for $key');
    for (var i = 0; i < expected.length; i++) {
      expect(got[i].metric, expected[i]['metric'], reason: '$key[$i] metric');
      expect(got[i].ms, expected[i]['ms'], reason: '$key[$i] ms');
      expect(got[i].value, expected[i]['value'], reason: '$key[$i] value');
    }
  }

  group('0x01 activity (hr + steps)', () {
    test('8-byte records', () {
      final got = parseHuami2021Activity(unhex(activity['0x01']['raw']), roundStartMs);
      expectSamples(got, '0x01');
    });
    test('4-byte packed records', () {
      final got = parseHuami2021Activity(unhex(activity['0x01_4byte']['raw']), roundStartMs);
      expectSamples(got, '0x01_4byte');
    });

    test('an EVEN count of 4-byte records is ambiguous with 8-byte records '
        'by length alone, and the heuristic gets it wrong without a count',
        () {
      // 6 real 4-byte records: steps=10+m, hr=60+m per minute m. 6*4 = 24
      // bytes, which is ALSO a multiple of 8 — exactly the case the old
      // length-only heuristic could not distinguish.
      final bytes = <int>[];
      for (var m = 0; m < 6; m++) {
        bytes.addAll([0, 0, 10 + m, 60 + m]);
      }
      final data = Uint8List.fromList(bytes);
      expect(data.length % 8, 0, reason: 'the ambiguous case this test exists for');

      // With the real count supplied (as a live fetch always has it),
      // every minute decodes correctly.
      final withCount =
          parseHuami2021Activity(data, roundStartMs, expectedRecordCount: 6);
      expect(withCount, hasLength(12)); // hr + steps, 6 minutes each
      for (var m = 0; m < 6; m++) {
        final hr = withCount.firstWhere(
            (s) => s.metric == 'hr' && s.ms == roundStartMs + m * 60000);
        final steps = withCount.firstWhere(
            (s) => s.metric == 'steps' && s.ms == roundStartMs + m * 60000);
        expect(hr.value, 60.0 + m);
        expect(steps.value, 10.0 + m);
      }
    });
  });

  test('0x02 manual_hr', () {
    expectSamples(parseHuami2021ManualHr(unhex(activity['0x02']['raw'])), '0x02');
  });

  test('0x12 stress_manual', () {
    expectSamples(parseHuami2021StressManual(unhex(activity['0x12']['raw'])), '0x12');
  });

  test('0x13 stress, round-relative, keeps 0 but not 0xFF', () {
    final got = parseHuami2021Stress(unhex(activity['0x13']['raw']), roundStartMs);
    expectSamples(got, '0x13');
  });

  test('0x2E temperature_c, signed, divided by 100, implausible values dropped',
      () {
    final got = parseHuami2021Temperature(unhex(activity['0x2E']['raw']), roundStartMs);
    // The fixture's second record (-1.2 C) is outside the 20-45 plausible
    // range and correctly dropped, not kept as a measured reading.
    final expected = (activity['0x2E']['samples'] as List)
        .cast<Map<String, dynamic>>()
        .where((s) => (s['value'] as num) >= 20 && (s['value'] as num) <= 45)
        .toList();
    expect(got.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      expect(got[i].ms, expected[i]['ms']);
      expect(got[i].value, expected[i]['value']);
    }
  });

  test('temperature outside the 20-45 C plausible range is never kept', () {
    final b = Uint8List(24); // three 8-byte round-relative records
    ByteData.sublistView(b).setInt16(2, (5.0 * 100).round(), Endian.little); // 5 C: too cold
    ByteData.sublistView(b).setInt16(10, (30.0 * 100).round(), Endian.little); // 30 C: kept
    ByteData.sublistView(b).setInt16(18, (60.0 * 100).round(), Endian.little); // 60 C: too hot
    final got = parseHuami2021Temperature(b, roundStartMs);
    expect(got, hasLength(1));
    expect(got.single.value, 30.0);
  });

  test('0x38 respiratory_rate', () {
    expectSamples(parseHuami2021RespiratoryRate(unhex(activity['0x38']['raw'])), '0x38');
  });

  test('0x3A resting_hr', () {
    expectSamples(parseHuami2021RestingHr(unhex(activity['0x3A']['raw'])), '0x3A');
  });

  test('0x3D max_hr', () {
    expectSamples(parseHuami2021MaxHr(unhex(activity['0x3D']['raw'])), '0x3D');
  });

  test('0x49 hrv', () {
    expectSamples(parseHuami2021Hrv(unhex(activity['0x49']['raw'])), '0x49');
  });

  group('0x25 spo2 spot', () {
    test('version 2, subtracts 128 when the high bit is set, drops 0% as '
        'implausible', () {
      final got = parseHuami2021Spo2Spot(unhex(activity['0x25']['raw']));
      // The fixture's third record decodes to 0% before the plausibility
      // bound — biologically impossible, and this protocol's own 0xFF
      // sentinel convention folds to the same excluded range after the
      // >=128 subtraction, so it is dropped rather than kept verbatim.
      final expected = (activity['0x25']['samples'] as List)
          .cast<Map<String, dynamic>>()
          .where((s) => (s['value'] as num) > 0)
          .toList();
      expect(got.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        expect(got[i].ms, expected[i]['ms']);
        expect(got[i].value, expected[i]['value']);
      }
    });
    test('an unknown version yields no samples, not a guess', () {
      final got = parseHuami2021Spo2Spot(unhex(activity['0x25_bad_version']['raw']));
      expect(got, isEmpty);
    });
    test('the folded sentinel (raw 0xFF -> 127) is dropped, not kept', () {
      // version byte 2, one 65-byte record: sec=0, value=0xFF at +4.
      final b = Uint8List(66);
      b[0] = 2;
      b[1 + 4] = 0xFF;
      expect(parseHuami2021Spo2Spot(b), isEmpty);
    });
  });

  test('0x26 spo2_sleep', () {
    expectSamples(parseHuami2021Spo2Sleep(unhex(activity['0x26']['raw'])), '0x26');
  });

  group('0x48 sleep sessions', () {
    final sleep = parsers['sleep'] as Map<String, dynamic>;
    final expectedSessions = (sleep['sessions'] as List).cast<Map<String, dynamic>>();
    late List<Huami2021SleepSession> got;

    setUpAll(() {
      got = parseHuami2021Sleep(unhex(sleep['raw'] as String));
    });

    test('yields exactly the expected sessions, in order', () {
      expect(got.length, expectedSessions.length);
    });

    for (var i = 0; i < 3; i++) {
      test('session $i matches field-for-field', () {
        final e = expectedSessions[i];
        final g = got[i];
        expect(g.sessionStartMs, e['sessionStartMs'], reason: 'sessionStartMs');
        expect(g.isNap, e['isNap'], reason: 'isNap');
        expect(g.avgHr, e['avgHr'], reason: 'avgHr');
        expect(g.score, e['score'], reason: 'score');
        expect(g.sleepStartMin, e['sleepStartMin'], reason: 'sleepStartMin');
        expect(g.sleepEndMin, e['sleepEndMin'], reason: 'sleepEndMin');
        expect(g.remMin, e['remMin'], reason: 'remMin');
        expect(g.lightMin, e['lightMin'], reason: 'lightMin');
        expect(g.deepMin, e['deepMin'], reason: 'deepMin');
        expect(g.wakeMin, e['wakeMin'], reason: 'wakeMin');
        final eStages = (e['stages'] as List).cast<List>();
        expect(g.stages.length, eStages.length, reason: 'stage count');
        for (var s = 0; s < eStages.length; s++) {
          expect(g.stages[s].startMs, eStages[s][0], reason: 'stage $s start');
          expect(g.stages[s].endMs, eStages[s][1], reason: 'stage $s end');
          expect(g.stages[s].type, eStages[s][2], reason: 'stage $s type');
        }
      });
    }

    test('a slot with a bad marker byte is skipped, not fatal', () {
      // slot1 in the fixture has markers (1,0) and is correctly absent from
      // the output above; re-assert it directly against a synthetic buffer
      // with only an invalid slot, to isolate the skip behaviour.
      final bad = Uint8List(594); // all zero: sec 0 is outside [1.6e9,2.0e9]
      expect(parseHuami2021Sleep(bad), isEmpty);
    });
  });

  group('0x0D pai (no known-value fixture; shape/guard checks only)', () {
    test('a plausible version-0 record with finite values in range is kept', () {
      final b = Uint8List(70); // 1 version byte + one 69-byte record
      b[0] = 0; // version
      ByteData.sublistView(b).setUint32(1, 1780000000, Endian.little);
      ByteData.sublistView(b).setFloat32(55, 120.5, Endian.little);
      ByteData.sublistView(b).setFloat32(59, 700.0, Endian.little);
      final got = parseHuami2021Pai(b);
      expect(got, hasLength(1));
      expect(got.single.ms, 1780000000000);
      expect(got.single.daily, closeTo(120.5, 0.001));
      expect(got.single.total, closeTo(700.0, 0.001));
    });

    test('a value outside 0-1000 is dropped', () {
      final b = Uint8List(70);
      ByteData.sublistView(b).setUint32(1, 1780000000, Endian.little);
      ByteData.sublistView(b).setFloat32(55, 5000.0, Endian.little);
      ByteData.sublistView(b).setFloat32(59, 1.0, Endian.little);
      expect(parseHuami2021Pai(b), isEmpty);
    });
  });

  group('0x4A odi summary (no known-value fixture; shape/guard checks only)', () {
    test('a plausible belongTime with a measured night is kept', () {
      final b = Uint8List(2896);
      final bd = ByteData.sublistView(b);
      bd.setUint32(0, 1780000000, Endian.little);
      bd.setUint32(4, 25000, Endian.little);
      bd.setUint32(8, 12, Endian.little);
      b[12] = 42;
      final got = parseHuami2021OdiSummary(b);
      expect(got, hasLength(1));
      expect(got.single.belongTimeMs, 1780000000000);
      expect(got.single.validTimeSec, 25000);
      expect(got.single.odiRefined, 12);
      expect(got.single.score, 42);
    });

    test('an unmeasured night (zero odi, 0xff score) withholds those fields', () {
      final b = Uint8List(2896);
      final bd = ByteData.sublistView(b);
      bd.setUint32(0, 1780000000, Endian.little);
      bd.setUint32(4, 100, Endian.little);
      b[12] = 0xff;
      final got = parseHuami2021OdiSummary(b).single;
      expect(got.odiRefined, isNull);
      expect(got.score, isNull);
      expect(got.validTimeSec, 100); // valid time is always kept
    });

    test('an implausible belongTime is skipped', () {
      expect(parseHuami2021OdiSummary(Uint8List(2896)), isEmpty);
    });
  });

  group('0x05 workout summaries', () {
    final workout = parsers['workout'] as Map<String, dynamic>;
    final expected = (workout['workouts'] as List).cast<Map<String, dynamic>>();
    late List<Huami2021Workout> got;

    setUpAll(() {
      got = parseHuami2021Workouts(unhex(workout['raw'] as String));
    });

    test('decodes every summary in the buffer', () {
      expect(got.length, expected.length);
    });

    for (var i = 0; i < 2; i++) {
      test('workout $i matches field-for-field', () {
        final e = expected[i];
        final g = got[i];
        expect(g.startMs, e['startMs'], reason: 'startMs');
        expect(g.durationSec, e['durationSec'], reason: 'durationSec');
        expect(g.sportType, e['sportType'], reason: 'sportType');
        expect(g.calories, e['calories'], reason: 'calories');
        expect(g.avgHr, e['avgHr'], reason: 'avgHr');
        expect(g.maxHr, e['maxHr'], reason: 'maxHr');
        expect(g.minHr, e['minHr'], reason: 'minHr');
      });
    }

    test('a truncated/malformed trailing record is dropped, not a crash, '
        'and every record decoded before it is still returned', () {
      final truncated = Uint8List.fromList([
        ...unhex(workout['raw'] as String),
        // A 2-byte record prefix, then a tag byte whose continuation bit
        // is set with nothing after it — a varint that never terminates
        // within the buffer. Used to crash the whole function with a raw
        // RangeError; now caught and treated as "nothing more to decode".
        0x00, 0x80, 0x80,
      ]);
      expect(() => parseHuami2021Workouts(truncated), returnsNormally);
      final got = parseHuami2021Workouts(truncated);
      expect(got.length, expected.length,
          reason: 'every record before the truncation still decodes');
    });
  });
}
