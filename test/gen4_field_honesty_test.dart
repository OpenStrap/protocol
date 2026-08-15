// gen4 decoder honesty: the fields we removed/renamed, and the two live-packet
// fabrications, checked against REAL records rather than synthetic bytes
// wherever the bytes exist in decode_parity_cases.json.
//
// The point of every assertion here is the "never fabricate" contract: when the
// bytes are not the quantity a field name claims, the decoder must emit ABSENCE
// (or an honestly-named raw value), never a plausible-looking number.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// Every real v24 historical record in the parity corpus, as raw inner bytes.
List<Uint8List> _realV24Records() {
  final cases =
      json.decode(File('decode_parity_cases.json').readAsStringSync()) as List;
  final out = <Uint8List>[];
  for (final c in cases) {
    final hex = (c as Map)['hex'] as String;
    if (hex.length != 192) continue;
    final b = hexToBytes(hex);
    if (b[1] == 24) out.add(b);
  }
  return out;
}

/// Every real 0x28 realtime packet in the parity corpus, as hex.
List<String> _real0x28Packets() {
  final cases =
      json.decode(File('decode_parity_cases.json').readAsStringSync()) as List;
  return [
    for (final c in cases)
      if (((c as Map)['hex'] as String).startsWith('28')) c['hex'] as String,
  ];
}

ByteData _view(Uint8List b) =>
    b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);

/// Build a 20-byte 0x28 realtime packet: ts@2, hr@8, rr_count@9, four R-R slots
/// at [10][12][14][16], wearing byte @[18]. [wearing] is deliberately a value
/// that also reads as a plausible R-R interval, so a decoder that walks past the
/// four real slots gets caught instead of being rescued by the range check.
Uint8List _packet0x28({
  required int declaredCount,
  required List<int> rr,
  int wearing = 1000,
  int hr = 60,
  int ts = 1780840486,
}) {
  final b = Uint8List(20);
  final v = _view(b);
  b[0] = 0x28;
  v.setUint32(2, ts, Endian.little);
  b[8] = hr;
  b[9] = declaredCount;
  for (int i = 0; i < rr.length; i++) {
    v.setInt16(10 + 2 * i, rr[i], Endian.little);
  }
  v.setInt16(18, wearing, Endian.little);
  return b;
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('0x28 realtime R-R is capped at the four slots the packet has', () {
    test('a full count of 4 decodes all four slots', () {
      final r = realtimeRr(_hex(
        _packet0x28(declaredCount: 4, rr: [800, 810, 820, 830]),
      ));
      expect(r, isNotNull);
      expect(r!.rrMs, [800, 810, 820, 830]);
    });

    test('a declared count of 5..8 is rejected outright, not truncated', () {
      // The packet is only 20 bytes: slot 5 starts at [18], which is the
      // wearing byte. Accepting the count and letting the loop bound stop it
      // would publish that byte as a heartbeat.
      for (int n = 5; n <= 8; n++) {
        final hex = _hex(_packet0x28(
          declaredCount: n,
          rr: [800, 810, 820, 830],
        ));
        expect(realtimeRr(hex), isNull, reason: 'declared count $n');
      }
    });

    test('the wearing byte at [18] never surfaces as an R-R interval', () {
      // wearing=1000 sits squarely inside the 200-2500 ms physiological range,
      // so the range check alone cannot filter it out.
      for (int n = 1; n <= 8; n++) {
        final r = realtimeRr(_hex(_packet0x28(
          declaredCount: n,
          rr: [800, 810, 820, 830],
          wearing: 1000,
        )));
        expect(r?.rrMs ?? const <int>[], isNot(contains(1000)),
            reason: 'declared count $n');
      }
    });

    test('R10 keeps the historical ceiling — its slots are really there', () {
      // R10 declares the count at [18] and carries values from [19] inside a
      // 1920-byte record, so 8 is genuine there and must not be capped to 4.
      final b = Uint8List(1920);
      final v = _view(b);
      b[0] = 0x2b;
      b[1] = 0x0a;
      v.setUint32(7, 1780840486, Endian.little);
      const r10Max = 8; // records.dart's kMaxRrPerRecord (not exported)
      b[18] = r10Max;
      for (int i = 0; i < r10Max; i++) {
        v.setInt16(19 + 2 * i, 800 + i, Endian.little);
      }
      final r = realtimeRr(_hex(b));
      expect(r, isNotNull);
      expect(r!.rrMs.length, r10Max);
    });

    test('real 0x28 packets still decode exactly as before', () {
      // Every 0x28 packet in the corpus declares zero R-R intervals, so the cap
      // must not have changed their outcome.
      final packets = _real0x28Packets();
      expect(packets, isNotEmpty);
      for (final hex in packets) {
        expect(realtimeRr(hex), isNull);
      }
    });
  });

  group('0x28 carries no IMU, so it reports no motion', () {
    test('real 0x28 packets yield null activity and null steps', () {
      final packets = _real0x28Packets();
      expect(packets, isNotEmpty);
      for (final hex in packets) {
        final s = decodeRecord(hex);
        expect(s, isNotNull, reason: hex);
        expect(s!.recType, 28);
        // Absence, not a measured zero: a 20-byte packet of timing + HR + R-R
        // + a wearing byte has no accelerometer window to average.
        expect(s.activity, isNull, reason: hex);
        expect(s.stepsInc, isNull, reason: hex);
      }
    });

    test('the packet still carries its timestamp and HR', () {
      final s = decodeRecord(_hex(_packet0x28(
        declaredCount: 0,
        rr: const [],
        hr: 77,
        ts: 1780840486,
      )))!;
      expect(s.ts, 1780840486);
      expect(s.hr, 77);
      expect(s.wristOn, isTrue);
    });
  });

  group('deprecated v24 fields — the bytes are not the quantity they name', () {
    late final List<Uint8List> records;
    setUpAll(() {
      records = _realV24Records();
      expect(records.length, 1887, reason: 'real v24 records in the corpus');
    });

    test('ppgRedIr: a u16@31 straddles the float32 at 32', () {
      // inner[32:36] is a well-formed float32 in every record, which means the
      // high byte of a u16 read at 31 is that float's mantissa LSB — so the
      // "PPG count" is one real byte glued to one bit of something else.
      for (final b in records) {
        final f = _view(b).getFloat32(32, Endian.little);
        expect(f.isFinite, isTrue);
        expect(f, greaterThan(0.0));
        expect(f, lessThan(4.0));
      }
    });

    test('skinContact: a float32 exponent byte, not a 0-198 quality scale', () {
      // inner[48:52] is an integer-valued float32 whose low byte is always
      // zero; inner[51] is its sign+exponent byte, which is the whole reason
      // the "quality" only ever takes values in {0, 63-70, 194-198}.
      const exponentBytes = {
        0, 63, 64, 65, 66, 67, 68, 69, 70, 194, 195, 196, 197, 198,
      };
      for (final b in records) {
        final f = _view(b).getFloat32(48, Endian.little);
        expect(f, f.roundToDouble());
        expect(b[48], 0);
        expect(exponentBytes, contains(b[51]));
      }
    });

    test('the map keys stay exactly as they are — oracle + shipped schema', () {
      // These names are wrong but frozen: the parity oracle checks the key set
      // 1:1, and they are live SQLite columns downstream. The deprecation
      // annotations carry the truth; the wire shape must not move.
      final map = parseR24(records.first)!.toMap();
      for (final k in const [
        'ppg_red_ir',
        'skin_contact',
        'skin_temp_raw',
        'ppg_green',
        'spo2_red_raw',
        'spo2_ir_raw',
        'ambient_raw',
      ]) {
        expect(map.containsKey(k), isTrue, reason: k);
      }
    });
  });

  group('skinTempRaw is not a temperature', () {
    test('it is still exactly the u16 at inner[68]', () {
      for (final b in _realV24Records()) {
        expect(parseR24(b)!.skinTempRaw, _view(b).getUint16(68, Endian.little));
      }
    });

    test('it moves far too fast to be a temperature', () {
      // Consecutive 1 Hz records: this value jumps by whole counts per second
      // while HR barely moves. That is the measurement behind the deprecation.
      final records = _realV24Records();
      final byTs = <int, int>{};
      for (final b in records) {
        byTs[_view(b).getUint32(7, Endian.little)] =
            _view(b).getUint16(68, Endian.little);
      }
      final ts = byTs.keys.toList()..sort();
      final deltas = <int>[];
      for (int i = 1; i < ts.length; i++) {
        if (ts[i] - ts[i - 1] != 1) continue;
        deltas.add((byTs[ts[i]]! - byTs[ts[i - 1]]!).abs());
      }
      expect(deltas, isNotEmpty);
      final mean = deltas.reduce((a, b) => a + b) / deltas.length;
      expect(mean, greaterThan(1.0),
          reason: 'a real skin temperature cannot change $mean counts/second');
    });
  });

  group('gravity vector', () {
    test('inner[52:64] duplicates inner[36:48] — one vector, not two', () {
      for (final b in _realV24Records()) {
        expect(b.sublist(52, 64), b.sublist(36, 48));
      }
    });

    test('|accelG| averages ~1.046, so it is not absolute g', () {
      // Documented, deliberately NOT corrected: a scale factor fitted to this
      // corpus would be a fabricated calibration.
      final records = _realV24Records();
      double sum = 0;
      for (final b in records) {
        final a = parseR24(b)!.accelG;
        sum += math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
      }
      final mean = sum / records.length;
      expect(mean, closeTo(1.046, 0.005));
      // The decoder must not have silently normalised it to 1.0.
      expect((mean - 1.0).abs(), greaterThan(0.02));
    });
  });

  group('spo2RedRaw / spo2IrRaw are one signal', () {
    test('their difference is fixed while both channels drift together', () {
      // If a red/IR ratio carried oxygenation information, the two channels
      // would have to move independently. They do not: ir - red is a constant.
      final records = _realV24Records();
      final diffs = <int>{};
      final reds = <int>{};
      for (final b in records) {
        final r = parseR24(b)!;
        diffs.add(r.spo2IrRaw - r.spo2RedRaw);
        reds.add(r.spo2RedRaw);
      }
      expect(reds.length, greaterThan(10),
          reason: 'the red channel really does drift');
      expect(diffs.length, lessThan(reds.length ~/ 4),
          reason: 'ir - red is pinned, so the pair carries one signal');
    });
  });

  group('R10 step search: the cadences it can actually reach', () {
    test('gen4 R10 is 100 Hz — 100 samples per record, one record per second',
        () {
      final cases =
          json.decode(File('decode_parity_cases.json').readAsStringSync())
              as List;
      final ts = <int>{};
      int r10 = 0;
      for (final c in cases) {
        final hex = (c as Map)['hex'] as String;
        if (hex.length < 1370) continue;
        final b = hexToBytes(hex);
        if (b[1] != 0x0a) continue;
        r10++;
        // 100 int16 per axis at 85 / 285 / 485 — the arrays are 200 bytes apart.
        expect(b.length, greaterThanOrEqualTo(685));
        ts.add(_view(b).getUint32(7, Endian.little));
      }
      expect(r10, greaterThan(100));
      final sorted = ts.toList()..sort();
      int consecutive = 0;
      for (int i = 1; i < sorted.length; i++) {
        if (sorted[i] - sorted[i - 1] == 1) consecutive++;
      }
      // 100 samples arriving each second is 100 Hz. At 100 Hz the lag window
      // (7..40) resolves 150-857 steps/min, so walking (100-130 spm, lags
      // 46-60) is out of reach — which is why every real record below scores 0.
      expect(consecutive, greaterThan(sorted.length ~/ 2));
    });

    test('no real R10 record produces a step — an absence, not stillness', () {
      final cases =
          json.decode(File('decode_parity_cases.json').readAsStringSync())
              as List;
      int seen = 0;
      for (final c in cases) {
        final hex = (c as Map)['hex'] as String;
        if (hex.length < 1370) continue;
        final b = hexToBytes(hex);
        if (b[1] != 0x0a) continue;
        final s = decodeRecord(hex);
        if (s == null) continue;
        seen++;
        // steps == 0 with a non-null activity means "the window was read and
        // this search found no cadence it can see", NOT "the wrist was still".
        expect(s.stepsInc, 0);
        expect(s.activity, isNotNull);
      }
      expect(seen, greaterThan(100));
    });
  });
}
