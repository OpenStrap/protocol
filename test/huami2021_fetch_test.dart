// Huami2021/ZeppOS history-fetch protocol: synthetic tests (no captured
// device stream exists for this layer — see the file header in
// lib/src/huami2021_fetch.dart). These test the STATE/LOGIC, which is
// verifiable by construction, not a byte layout that needs real hardware.
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

String hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('time8 and the start request', () {
    test('encodes year LE, month, day, hour, minute, 0, tz in quarter-hours', () {
      final since = DateTime(2026, 3, 4, 13, 7);
      final t8 = huami2021Time8(since, 330); // UTC+5:30 → 22 quarters
      expect(t8.length, 8);
      expect(t8[0] | (t8[1] << 8), 2026);
      expect(t8[2], 3);
      expect(t8[3], 4);
      expect(t8[4], 13);
      expect(t8[5], 7);
      expect(t8[6], 0);
      expect(t8[7], 22);
    });

    test('a negative UTC offset still masks into one byte', () {
      final t8 = huami2021Time8(DateTime(2026, 1, 1), -300); // UTC-5:00
      expect(t8[7], (-20) & 0xFF);
    });

    test('start request is 0x01, type, then time8', () {
      final req = huami2021FetchStartRequest(
          kHuami2021TypeActivity, DateTime(2026, 1, 1, 0, 0), 0);
      expect(req[0], 0x01);
      expect(req[1], kHuami2021TypeActivity);
      expect(req.length, 10);
    });
  });

  group('start reply parsing', () {
    test('a real reply is parsed with status, expected, and roundStart', () {
      final b = Uint8List.fromList([
        0x10, 0x01, 0x01, // status ok
        0x05, 0x00, 0x00, 0x00, // expected = 5
        0xEA, 0x07, // year 2026 LE
        3, 4, 13, 7, 0, // month, day, hour, min, sec
      ]);
      final reply = parseHuami2021FetchStart(b)!;
      expect(reply.ok, isTrue);
      expect(reply.expected, 5);
      expect(reply.hasData, isTrue);
      expect(reply.roundStart, DateTime(2026, 3, 4, 13, 7, 0));
    });

    test('expected == 0 means hasData is false even on success', () {
      final b = Uint8List.fromList(
          [0x10, 0x01, 0x01, 0, 0, 0, 0, 0xEA, 0x07, 1, 1, 0, 0, 0]);
      expect(parseHuami2021FetchStart(b)!.hasData, isFalse);
    });

    test('an all-zero date falls back to 1970, never a silently-normalised '
        'garbage date', () {
      final b = Uint8List.fromList(
          [0x10, 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      // Dart's DateTime(0, 0, 0, ...) would otherwise silently become
      // -0001-11-30 instead of failing — this must never reach a caller.
      expect(parseHuami2021FetchStart(b)!.roundStart, DateTime(1970));
    });

    test('an implausible month/day/hour/minute/second falls back to 1970',
        () {
      final b = Uint8List.fromList(
          [0x10, 0x01, 0x01, 1, 0, 0, 0, 0xEA, 0x07, 13, 32, 24, 60, 60]);
      expect(parseHuami2021FetchStart(b)!.roundStart, DateTime(1970));
    });

    test('a non-success status is not hasData', () {
      final b = Uint8List.fromList(
          [0x10, 0x01, 0x02, 5, 0, 0, 0, 0xEA, 0x07, 1, 1, 0, 0, 0]);
      final reply = parseHuami2021FetchStart(b)!;
      expect(reply.ok, isFalse);
      expect(reply.hasData, isFalse);
    });

    test('an unrelated or too-short payload is not a start reply', () {
      expect(parseHuami2021FetchStart(Uint8List.fromList([0x01, 0x02])), isNull);
      expect(parseHuami2021FetchStart(Uint8List.fromList([0x10, 0x02, 1])), isNull);
    });
  });

  test('round-end reply', () {
    expect(parseHuami2021FetchRoundEnd(Uint8List.fromList([0x10, 0x02, 0x01])), 0x01);
    expect(parseHuami2021FetchRoundEnd(Uint8List.fromList([0x10, 0x01, 0x01])), isNull);
  });

  group('Huami2021FetchBuffer', () {
    test('reassembles contiguous packets, stripping the counter byte', () {
      final buf = Huami2021FetchBuffer();
      buf.add([0, 1, 2, 3]);
      buf.add([1, 4, 5]);
      buf.add([2, 6]);
      expect(buf.ok, isTrue);
      expect(buf.bytes, [1, 2, 3, 4, 5, 6]);
    });

    test('a counter gap flips ok false and further packets are ignored', () {
      final buf = Huami2021FetchBuffer();
      buf.add([0, 1]);
      buf.add([2, 9]); // should have been 1
      expect(buf.ok, isFalse);
      buf.add([2, 9]); // ignored: round already discarded
      expect(buf.bytes, [1]);
    });

    test('the counter wraps at 0xFF back to 0', () {
      final buf = Huami2021FetchBuffer();
      var expectedCounter = 0;
      for (var i = 0; i < 260; i++) {
        buf.add([expectedCounter & 0xff, i]);
        expectedCounter++;
      }
      expect(buf.ok, isTrue);
      expect(buf.bytes.length, 260);
    });
  });

  group('count validation', () {
    test('type 0x01 expected is a record count, 8 bytes per record', () {
      expect(huami2021FetchCountMatches(kHuami2021TypeActivity, 3, 24), isTrue);
      expect(huami2021FetchCountMatches(kHuami2021TypeActivity, 3, 20), isFalse);
    });
    test('type 0x01 falls back to 4-byte records when length is not a multiple of 8', () {
      expect(huami2021FetchCountMatches(kHuami2021TypeActivity, 3, 12), isTrue);
    });
    test('every other type is a plain byte count', () {
      expect(huami2021FetchCountMatches(kHuami2021TypeStress, 10, 10), isTrue);
      expect(huami2021FetchCountMatches(kHuami2021TypeStress, 10, 9), isFalse);
    });
  });

  group('gap-skip paging', () {
    test('activity: minutes = rawLen / recordSize, clamped 1-1440', () {
      expect(huami2021FetchGapSkipMinutes(kHuami2021TypeActivity, 24), 3);
      expect(huami2021FetchGapSkipMinutes(kHuami2021TypeActivity, 0), 1); // clamp up
      expect(huami2021FetchGapSkipMinutes(kHuami2021TypeActivity, 100000), 1440); // clamp down
    });
    test('stress: record size is 1 byte, so minutes == rawLen', () {
      expect(huami2021FetchGapSkipMinutes(kHuami2021TypeStress, 7), 7);
    });
    test('any other type is not a gap-skip type', () {
      expect(() => huami2021FetchGapSkipMinutes(kHuami2021TypeSleep, 10),
          throwsArgumentError);
    });
  });
}
