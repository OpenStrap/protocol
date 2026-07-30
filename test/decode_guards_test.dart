// Regression tests for the decode guards that keep the package's "never
// fabricate" contract: a decoder must emit ABSENCE, not a plausible-looking
// default, when the bytes do not actually carry the field.
//
// Every test here fails against the pre-guard behavior.

import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// Record 0 of the golden capture — a real, CRC-valid v24 historical record
/// (inner starts at packet type 0x2f). 96 bytes. Every mutation below starts
/// from this known-good record so the ONLY thing under test is the guard.
const String _goodV24 =
    '2f1805f13ced01c261d2698848805454016202d802f5010000000000609f0fff80de23'
    '3d3dda19be5c87a9be7b14803f0020dc463dda19be5c87a9be7b14803f16028402bc02'
    '86025e01000b010c020c0000000000370001510c000000000000';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A copy of [hex] with [patch]'s byte values written at their offsets.
String _patched(String hex, Map<int, int> patch) {
  final b = Uint8List.fromList(hexToBytes(hex));
  patch.forEach((off, v) => b[off] = v);
  return _hex(b);
}

/// Build a compact 0x28 realtime-HR inner frame:
/// `[0x28][rec][ts u32 @2][..][hr @8][rr_count @9][rr @10,12,14,16][wearing @18]`
Uint8List _realtimeHrFrame({
  required int ts,
  required int hr,
  required int declaredCount,
  required List<int> rrMs,
}) {
  final b = Uint8List(19);
  final v = ByteData.sublistView(b);
  b[0] = 0x28;
  b[1] = 0x01;
  v.setUint32(2, ts, Endian.little);
  b[8] = hr;
  b[9] = declaredCount;
  for (int i = 0; i < rrMs.length && i < 4; i++) {
    v.setUint16(10 + 2 * i, rrMs[i], Endian.little);
  }
  b[18] = 1; // wearing
  return b;
}

/// Wrap a COMMAND_RESPONSE body: `[0x24][seq][opcode] + payload`.
Uint8List _cmdResponse(int opcode, List<int> payload) =>
    Uint8List.fromList([0x24, 0x11, opcode, ...payload]);

List<int> _u32le(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  // ── 1. R-R count / value bounds in the historical record decoder ──────────
  group('R24 R-R intervals are bounded (count + physiological value)', () {
    test('baseline: the unmodified record still decodes its 2 real beats', () {
      final r = parseR24(hexToBytes(_goodV24))!;
      expect(r.rrCount, 2);
      expect(r.rrIntervalsMs, [728, 501]);
    });

    test('an implausible declared count yields NO intervals, not 38 of them',
        () {
      // inner[18] = 0x28 (40). Taken raw this reads 40 int16s from [19:99],
      // turning ppg@29/31, the accel float32s@36/40/44, skin contact@51,
      // spo2@64/66, skin temp@68 and ambient@70 into "beats" that feed HRV.
      final r = parseR24(hexToBytes(_patched(_goodV24, {18: 0x28})))!;
      expect(r.rrCount, 0, reason: 'count above the ceiling must be rejected');
      expect(r.rrIntervalsMs, isEmpty);
    });

    test('the count guard applies on the TRUSTED v24/v12 path too', () {
      // v24 and v12 skip the physiological-plausibility gate entirely, so the
      // R-R guard has to be independent of it.
      for (final version in [24, 12]) {
        final r = parseR24(
            hexToBytes(_patched(_goodV24, {1: version, 18: 0xff})))!;
        expect(r.rrCount, 0, reason: 'v$version must still bound the count');
        expect(r.rrIntervalsMs, isEmpty, reason: 'v$version');
      }
    });

    test('an R-R value below the physiological floor is dropped', () {
      // count=1, interval = 5 ms (12000 bpm). The old filter was only `v > 0`.
      final r = parseR24(
          hexToBytes(_patched(_goodV24, {18: 1, 19: 0x05, 20: 0x00})))!;
      expect(r.rrIntervalsMs, isEmpty);
      expect(r.rrCount, 0);
    });

    test('an R-R value above the physiological ceiling is dropped', () {
      // count=1, interval = 30000 ms as int16 → 30000 is > 2500 ms (24 bpm).
      final r = parseR24(
          hexToBytes(_patched(_goodV24, {18: 1, 19: 0x30, 20: 0x75})))!;
      expect(r.rrIntervalsMs, isEmpty);
      expect(r.rrCount, 0);
    });

    test('rrCount reports what was accepted, never the raw declared byte', () {
      // count=2, first beat valid (800 ms), second beat 1 ms → 1 accepted.
      final r = parseR24(hexToBytes(_patched(_goodV24, {
        18: 2,
        19: 0x20, 20: 0x03, // 800
        21: 0x01, 22: 0x00, //   1
      })))!;
      expect(r.rrIntervalsMs, [800]);
      expect(r.rrCount, r.rrIntervalsMs.length);
    });

    test('FirmwareAwareR24Decoder inherits the same bounds', () {
      final r = FirmwareAwareR24Decoder()
          .decode(hexToBytes(_patched(_goodV24, {18: 0x28})))!;
      expect(r.rrCount, 0);
      expect(r.rrIntervalsMs, isEmpty);
    });
  });

  // ── 2. Non-finite accel is rejected, never rounded to 0.0 ────────────────
  group('R24 rejects a non-finite accel vector', () {
    // float32 quiet-NaN / +Infinity little-endian byte patterns.
    const nan = [0x00, 0x00, 0xc0, 0x7f];
    const inf = [0x00, 0x00, 0x80, 0x7f];

    Map<int, int> at(int off, List<int> bytes) =>
        {for (int i = 0; i < bytes.length; i++) off + i: bytes[i]};

    test('a CRC-valid v24 record with NaN accel decodes to null', () {
      for (final off in [36, 40, 44]) {
        final r = parseR24(hexToBytes(_patched(_goodV24, at(off, nan))));
        expect(r, isNull, reason: 'NaN at inner[$off] must reject the record');
      }
    });

    test('an Infinity accel component decodes to null', () {
      for (final off in [36, 40, 44]) {
        final r = parseR24(hexToBytes(_patched(_goodV24, at(off, inf))));
        expect(r, isNull, reason: '+Inf at inner[$off] must reject the record');
      }
    });

    test('the guard covers the trusted v12 path, not just the validated ones',
        () {
      final r = parseR24(
          hexToBytes(_patched(_goodV24, {1: 12, ...at(36, nan)})));
      expect(r, isNull);
    });

    test('FirmwareAwareR24Decoder also rejects it (no fallback laundering)',
        () {
      final r = FirmwareAwareR24Decoder()
          .decode(hexToBytes(_patched(_goodV24, at(40, nan))));
      expect(r, isNull);
    });

    test('a finite accel record is unaffected', () {
      final r = parseR24(hexToBytes(_goodV24))!;
      expect(r.accelG.every((c) => c.isFinite), isTrue);
      expect(r.accelG[2], closeTo(1.0006, 1e-4));
    });
  });

  // ── 3. decodeRecord routes every known historical version ────────────────
  group('decodeRecord routes all historical record versions', () {
    test('v12 carries its OWN timestamp instead of decoding to null', () {
      final s = decodeRecord(_patched(_goodV24, {1: 12}));
      expect(s, isNotNull,
          reason: 'Record.r12 is real firmware and must not fall through');
      expect(s!.ts, 1775395266);
      expect(s.hr, 98);
      expect(s.recType, 12);
    });

    test('v9 and v18 route through parseR24 as well', () {
      for (final version in [9, 18]) {
        final s = decodeRecord(_patched(_goodV24, {1: version}));
        expect(s, isNotNull, reason: 'v$version must be routed');
        expect(s!.ts, 1775395266, reason: 'v$version ts');
        expect(s.recType, version);
      }
    });

    test('routing does NOT bypass the plausibility gate', () {
      // v7 reads HR at inner[27], which is 0 in this record → implausible, so
      // parseR24 declines and decodeRecord must surface that as null rather
      // than a 0-bpm sample.
      expect(decodeRecord(_patched(_goodV24, {1: 7})), isNull);
    });

    test('v24 / v25 behavior is unchanged', () {
      final s = decodeRecord(_goodV24)!;
      expect(s.recType, 24);
      expect(s.ts, 1775395266);
    });

    test('an unknown version is still not routed here', () {
      // Only versions with a field map are routed; anything else stays null so
      // decodeRecord never invents a timestamp for a layout we cannot read.
      expect(decodeRecord(_patched(_goodV24, {1: 11})), isNull);
    });

    test('the routed historical family reports null activity/steps, not 0/0',
        () {
      // v7/v9/v12/v18/v24 carry no IMU stepping window at all — that is the
      // same "no usable IMU data" absence as a truncated R10, not a measured
      // zero-motion reading. Fabricating 0 here silently misreports "this
      // record type cannot say" as "the wrist was still".
      for (final version in [9, 12, 18, 24]) {
        final s = decodeRecord(_patched(_goodV24, {1: version}))!;
        expect(s.activity, isNull, reason: 'v$version activity');
        expect(s.stepsInc, isNull, reason: 'v$version stepsInc');
      }
    });
  });

  // ── 4. parseRealtimeHr reads every declared R-R slot ─────────────────────
  group('parseRealtimeHr R-R extraction', () {
    test('all four declared intervals are returned, not just the first two',
        () {
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 4,
        rrMs: [800, 810, 820, 830],
      );
      expect(parseRealtimeHr(f)!.rrMs, [800, 810, 820, 830]);
    });

    test('it agrees with live.dart realtimeRr on the same bytes', () {
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 3,
        rrMs: [900, 910, 920],
      );
      expect(parseRealtimeHr(f)!.rrMs, realtimeRr(_hex(f))!.rrMs);
    });

    test('an implausible declared count yields no intervals at all', () {
      // 40 cannot fit the 4-slot wire form → we are reading the wrong offset.
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 40,
        rrMs: [800, 810, 820, 830],
      );
      expect(parseRealtimeHr(f)!.rrMs, isEmpty);
    });

    test('out-of-range slot values are dropped, in-range ones kept', () {
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 4,
        rrMs: [800, 5, 3000, 830],
      );
      expect(parseRealtimeHr(f)!.rrMs, [800, 830]);
    });
  });

  // ── 4b. live.dart realtimeRr shares the same physiological RR bound ──────
  group('realtimeRr is bounded like parseRealtimeHr', () {
    test('out-of-range slot values are dropped, in-range ones kept', () {
      // 5ms (12,000bpm) and 3000ms are outside kMinRrMs..kMaxRrMs; a
      // misaligned/corrupted 0x28 frame must not hand these to live HRV
      // compute just because realtimeRr forgot the bound control.dart and
      // records.dart both apply.
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 4,
        rrMs: [800, 5, 3000, 830],
      );
      expect(realtimeRr(_hex(f))!.rrMs, [800, 830]);
    });

    test('a frame with only out-of-range values yields no result at all', () {
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 2,
        rrMs: [5, 32000],
      );
      expect(realtimeRr(_hex(f)), isNull);
    });

    test('it still agrees with parseRealtimeHr once both are bounded', () {
      final f = _realtimeHrFrame(
        ts: 1775395266,
        hr: 62,
        declaredCount: 4,
        rrMs: [800, 5, 3000, 830],
      );
      expect(realtimeRr(_hex(f))!.rrMs, parseRealtimeHr(f)!.rrMs);
    });
  });

  // ── 5. GET_ALARM_TIME dispatches on the on-wire alarm form ───────────────
  group('GET_ALARM_TIME form dispatch', () {
    const epoch = 1775395266;

    test('the RICH (0x04) form reads the epoch at offset 2', () {
      // [0x04][u8 index][u32 epoch][u16 subsec][12-byte haptic pattern]
      final payload = <int>[
        0x04, 0x00, ..._u32le(epoch), 0x00, 0x40,
        ...kDefaultAlarmHaptics,
      ];
      expect(payload.length, 20);
      final r = parseCommandResponse(_cmdResponse(0x43, payload))!;
      expect(r.decoded['alarm_epoch'], epoch);
    });

    test('the rich form written by cmdSetAlarm round-trips', () {
      final when = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
      final frame = cmdSetAlarm(0, when);
      final inner = parseFrame(frame)!.inner;
      // inner = [0x23][seq][0x42] + payload (+ pad4); the response echoes the
      // same payload under opcode 0x43.
      final payload = inner.sublist(3);
      final r = parseCommandResponse(_cmdResponse(0x43, payload))!;
      expect(r.decoded['alarm_epoch'], epoch);
    });

    test('the SIMPLE (0x01) form still reads the epoch at offset 1', () {
      final payload = <int>[0x01, ..._u32le(epoch), 0x00, 0x40];
      expect(payload.length, 7);
      final r = parseCommandResponse(_cmdResponse(0x43, payload))!;
      expect(r.decoded['alarm_epoch'], epoch);
    });

    test('an unknown form emits no alarm_epoch rather than a guessed offset',
        () {
      final payload = <int>[0x07, 0x00, ..._u32le(epoch), 0x00, 0x40];
      final r = parseCommandResponse(_cmdResponse(0x43, payload))!;
      expect(r.decoded.containsKey('alarm_epoch'), isFalse);
    });
  });

  // ── 6. R10 motion: "not measured" is not "measured zero" ─────────────────
  group('R10 motion absence is distinguishable from a measured zero', () {
    // Truncated R10: header + HR present, but the accel arrays (which start at
    // [85] and run to [685]) are not.
    String shortR10() {
      final b = Uint8List(200);
      final v = ByteData.sublistView(b);
      b[0] = 0x2b;
      b[1] = 0x0a;
      v.setUint32(7, 1775395266, Endian.little);
      b[17] = 61;
      return _hex(b);
    }

    test('a truncated R10 reports null activity/steps, not 0.0/0', () {
      final s = decodeRecord(shortR10())!;
      expect(s.recType, 10);
      expect(s.ts, 1775395266);
      expect(s.hr, 61);
      expect(s.activity, isNull,
          reason: 'no IMU window was read — that is not a zero-motion reading');
      expect(s.stepsInc, isNull);
    });

    test('a full R10 still reports a measured activity', () {
      final full = File('test/r10_fixture.hex').readAsStringSync().trim();
      final s = decodeRecord(full)!;
      expect(s.activity, isNotNull);
      expect(s.activity, greaterThanOrEqualTo(0.0));
      expect(s.stepsInc, isNotNull);
    });

    test('toMap carries the absence through as null', () {
      expect(decodeRecord(shortR10())!.toMap()['activity'], isNull);
      expect(decodeRecord(shortR10())!.toMap()['steps_inc'], isNull);
    });
  });

  // ── 7. Battery percentages are bounded to 0..100 ─────────────────────────
  group('battery level is bounded', () {
    test('GET_BATTERY_LEVEL with 0xffff emits nothing, not 6553.5%', () {
      final r = parseCommandResponse(
          Uint8List.fromList([0x24, 0x11, 0x1a, 0x00, 0x00, 0xff, 0xff]))!;
      expect(r.decoded.containsKey('battery_pct'), isFalse);
    });

    test('an in-range battery level still decodes', () {
      final r = parseCommandResponse(
          Uint8List.fromList([0x24, 0x11, 0x1a, 0x00, 0x00, 0x2c, 0x01]))!;
      expect(r.decoded['battery_pct'], closeTo(30.0, 1e-9));
    });

    test('exactly 100.0% is accepted', () {
      final r = parseCommandResponse(
          Uint8List.fromList([0x24, 0x11, 0x1a, 0x00, 0x00, 0xe8, 0x03]))!;
      expect(r.decoded['battery_pct'], closeTo(100.0, 1e-9));
    });

    test('parseHello rejects an above-100% candidate instead of reporting it',
        () {
      // u16 @1 = 0x03ed = 1005 → 100.5%, which is not a battery percentage.
      // Every later offset is 0xffff, so nothing else qualifies → null.
      final payload = Uint8List.fromList(
          [0x00, 0xed, 0x03, ...List<int>.filled(9, 0xff)]);
      expect(parseHello(payload).batteryPct, isNull);
    });

    test('parseHello still reads a real battery field', () {
      // The real captured HELLO body: battery is 89.9% at offset 3.
      const body =
          'a001048303000000b196e201b0020000344332323438303932003865323738326237'
          '346634303238346333663437363138623062613234373663356431366363303533'
          '313862373532316431353635650600000002000000100000002900000011000000';
      final h = parseHello(hexToBytes(body));
      expect(h.batteryPct, isNotNull);
      expect(h.batteryPct!, inInclusiveRange(0.0, 100.0));
      expect(h.batteryPct, closeTo(89.9, 1e-9));
    });
  });

  // ── 8. cmdBuzz rejects an out-of-range pattern ───────────────────────────
  group('cmdBuzz pattern is range-checked', () {
    test('an out-of-u8 pattern throws instead of silently wrapping', () {
      // 300 & 0xff == 44: the old builder emitted a CRC-valid packet playing
      // waveform effect 44 with no indication anything was wrong.
      expect(() => cmdBuzz(0, 300), throwsA(isA<ArgumentError>()));
      expect(() => cmdBuzz(0, 256), throwsA(isA<ArgumentError>()));
      expect(() => cmdBuzz(0, -1), throwsA(isA<ArgumentError>()));
    });

    test('valid patterns still build the same bytes', () {
      expect(cmdBuzz(0), cmdBuzz(0, 2));
      expect(() => cmdBuzz(0, 255), returnsNormally);
      expect(() => cmdBuzz(0, 0), returnsNormally);
    });
  });

  group('hexToBytes', () {
    test('decodes both cases and tolerates surrounding whitespace', () {
      expect(hexToBytes('  0aFF10 '), equals([0x0a, 0xff, 0x10]));
      expect(hexToBytes(''), isEmpty);
    });

    test('rawTail snapshots the record, even if the buffer is reused', () {
      final inner = hexToBytes(_goodV24);
      final before = inner[13];
      final rec = parseR24(inner)!;
      // rawTail is encoded lazily, so the record must own its bytes: mutating
      // the caller's buffer afterwards must not change what it reports.
      inner[13] = before ^ 0xFF;
      expect(rec.rawTail.substring(0, 2),
          before.toRadixString(16).padLeft(2, '0'),
          reason: 'rawTail must reflect parse time, not later mutation');
    });

    test('throws on non-hex input instead of fabricating bytes', () {
      for (final bad in ['0g', 'zz', '0x', '00 11', 'a', 'abc']) {
        expect(() => hexToBytes(bad), throwsFormatException, reason: bad);
      }
    });
  });
}
