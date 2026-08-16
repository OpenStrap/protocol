// Four decode-integrity rules, each of which was violated by shipped code.
//
// The shared theme: a decoder must not turn "I cannot read this" into a
// confident wrong answer, and must not let one bad field cost a whole record.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// A gen4 historical record inner: `[0x2f][version][…][counter@3][ts@7]`.
Uint8List _record({
  required int version,
  int length = 89,
  int hrOffset = 17,
  int hr = 60,
  int rrCount = 4,
}) {
  final inner = Uint8List(length);
  inner[0] = PacketType.historicalData;
  inner[1] = version;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 1234, Endian.little);
  v.setUint32(7, 1780000000, Endian.little);
  inner[hrOffset] = hr;
  inner[18] = rrCount;
  for (var i = 0; i < rrCount; i++) {
    v.setInt16(19 + 2 * i, 800 + i, Endian.little); // in-range "beats"
  }
  // ~1 g so the plausibility gate passes.
  v.setFloat32(36, 0.0, Endian.little);
  v.setFloat32(40, 0.0, Endian.little);
  v.setFloat32(44, 1.0, Endian.little);
  return inner;
}

void main() {
  group('a record decoder only reads record packets', () {
    test('a control frame whose SEQUENCE byte is 24 is not a v24 record', () {
      // inner[1] is the version on a data frame and the SEQUENCE on a control
      // frame. Dispatching on it alone meant 2 in 256 of every control frame
      // decoded as a trusted v24 — which skips the plausibility gate — and
      // produced a heart rate and an accel vector read out of log text.
      final console = Uint8List(120);
      console[0] = PacketType.consoleLogs;
      console[1] = 24; // sequence, not a version
      expect(parseR24(console), isNull);
      expect(FirmwareAwareR24Decoder().decode(console), isNull);

      console[1] = 12; // the other trusted version
      expect(parseR24(console), isNull);
    });

    test('record types 10/11 still decode under BOTH packet types', () {
      // The gate must be {historical, realtime}: these two legitimately arrive
      // under either, and a historical-only gate would break live IMU.
      for (final pt in [PacketType.historicalData, PacketType.realtimeData]) {
        final inner = _record(version: 24);
        inner[0] = pt;
        expect(parseR24(inner), isNotNull, reason: 'packet type $pt');
      }
    });
  });

  group('R-R beats are read only where the field map is confirmed', () {
    test('v24 and v12 keep their beats', () {
      for (final version in [24, 12]) {
        final r = parseR24(_record(version: version));
        expect(r, isNotNull);
        expect(r!.rrIntervalsMs, hasLength(4), reason: 'v$version');
      }
    });

    test('a version with a different HR offset yields no beats', () {
      // v7 puts HR at 27 and v18 at 14 — proof the layout is not v24's — yet
      // rr_count@18 and the intervals from 19 were still read off v24's map.
      // The 200..2500 ms filter does not save that: arbitrary bytes land in
      // range often enough to hand RMSSD a full set of invented beats.
      for (final entry in {7: 27, 18: 14, 9: 17}.entries) {
        final r = parseR24(
            _record(version: entry.key, hrOffset: entry.value, hr: 60));
        expect(r, isNotNull, reason: 'v${entry.key} still decodes');
        expect(r!.rrIntervalsMs, isEmpty, reason: 'v${entry.key} beats');
        expect(r.rrCount, 0, reason: 'v${entry.key} count');
        expect(r.hr, 60, reason: 'v${entry.key} keeps the field it does know');
      }
    });
  });

  group('the optical block is read only where the field map is confirmed', () {
    // Same rule as the beats above: on a version whose layout is known to
    // differ, bytes at 29/64/66/68/70 are not the optical channels, and
    // relative-ODI would turn them into a desaturation number.
    Uint8List withOptical(int version, int hrOffset) {
      final inner = _record(version: version, hrOffset: hrOffset);
      final v = ByteData.sublistView(inner);
      v.setUint16(29, 1111, Endian.little); // ppg green
      inner[51] = 66; // skin contact byte
      v.setUint16(64, 2222, Endian.little); // spo2 red
      v.setUint16(66, 3333, Endian.little); // spo2 ir
      v.setUint16(68, 4444, Endian.little); // "skin temp"
      v.setUint16(70, 5555, Endian.little); // ambient
      return inner;
    }

    test('v24 keeps its optical block', () {
      final r = parseR24(withOptical(24, 17))!;
      expect(r.ppgGreen, 1111);
      expect(r.spo2RedRaw, 2222);
      expect(r.spo2IrRaw, 3333);
      expect(r.ambientRaw, 5555);
    });

    test('an unconfirmed version reports the optical block absent', () {
      for (final entry in {7: 27, 18: 14, 9: 17}.entries) {
        final r = parseR24(withOptical(entry.key, entry.value));
        expect(r, isNotNull, reason: 'v${entry.key} still decodes');
        expect(r!.ppgGreen, 0, reason: 'v${entry.key} ppg');
        expect(r.spo2RedRaw, 0, reason: 'v${entry.key} red');
        expect(r.spo2IrRaw, 0, reason: 'v${entry.key} ir');
        expect(r.ambientRaw, 0, reason: 'v${entry.key} ambient');
        expect(r.hr, 60, reason: 'v${entry.key} keeps HR and timing');
        expect(r.tsEpoch, 1780000000);
      }
    });
  });

  group('a gen5 v18 with an unusable accel keeps the rest of the record', () {
    test('an unusable accel is reported ABSENT, not fabricated and not fatal',
        () {
      // Declining the whole record used to be the lesser evil, because
      // decoded_onehz's ax/ay/az were REAL NOT NULL and absent would have been
      // stored as exact (0,0,0) — a perfectly still wrist. Storage can say
      // "absent" now (edge schema v39), so an unreadable accel costs the accel
      // and nothing else: HR, RR, steps and temperature from the same second
      // survive.
      final inner = Uint8List(kGen5V18InnerLen);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      final v = ByteData.sublistView(inner);
      v.setUint32(7, 1780000000, Endian.little);
      inner[14] = 102;
      v.setFloat32(33, double.nan, Endian.little);
      v.setFloat32(37, 4.0e6, Endian.little); // beyond any real full scale
      v.setFloat32(41, 4.0e6, Endian.little);
      v.setFloat32(45, 4.0e6, Endian.little);
      final g = parseGen5Historical(inner) as Gen5HistorySample?;
      expect(g, isNotNull);
      expect(g!.heartRate, 102);
      expect(g.gravityG, isEmpty, reason: 'absent, not (0,0,0)');
      expect(g.dynamicAccelerationG, isNull);
    });

    test('NO gen4 gravity window on gen5: hard motion still decodes', () {
      // gen4's magSq window [0.25, 3.24] is a bound on a NORMALISED GRAVITY
      // VECTOR. Gen5's gravityG is a different quantity — per-axis means of
      // raw accel — so a wrist in hard motion legitimately reads well above
      // 1.8 g, and the borrowed window rejected the whole record for exactly
      // the workout seconds that matter.
      final inner = Uint8List(kGen5V18InnerLen);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      final v = ByteData.sublistView(inner);
      v.setUint32(7, 1780000000, Endian.little);
      inner[14] = 165; // working hard
      v.setFloat32(33, 3.5, Endian.little);
      v.setFloat32(37, 2.5, Endian.little); // magSq = 18.75, far past 3.24
      v.setFloat32(41, 2.5, Endian.little);
      v.setFloat32(45, 2.5, Endian.little);
      final g = parseGen5Historical(inner) as Gen5HistorySample?;
      expect(g, isNotNull);
      expect(g!.heartRate, 165);
      expect(g.gravityG, [2.5, 2.5, 2.5]);
      expect(g.dynamicAccelerationG, 3.5);
    });

    test('an implausible HR costs the HR, not the record', () {
      // 240 bpm is an optical artefact, not a broken frame. Rejecting the whole
      // record threw away that second's beats, temp and steps as well — and the
      // band then trimmed them.
      final inner = Uint8List(kGen5V18InnerLen);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      final v = ByteData.sublistView(inner);
      v.setUint32(7, 1780000000, Endian.little);
      inner[14] = 240; // out of 25..230
      inner[15] = 2; // two beats
      v.setInt16(16, 800, Endian.little);
      v.setInt16(18, 810, Endian.little);
      v.setFloat32(33, 0.01, Endian.little);
      v.setFloat32(37, 0.0, Endian.little);
      v.setFloat32(41, 0.0, Endian.little);
      v.setFloat32(45, 1.0, Endian.little);
      v.setInt16(65, 3057, Endian.little);
      final g = parseGen5Historical(inner) as Gen5HistorySample?;
      expect(g, isNotNull);
      expect(g!.heartRate, 0, reason: 'absent, never the artefact bpm');
      expect(g.rrIntervalsMs, [800, 810]);
      expect(g.skinTempC, closeTo(30.57, 0.01));
    });

    test('a signal-quality float that is not finite comes back null', () {
      final inner = Uint8List(kGen5V18InnerLen);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      final v = ByteData.sublistView(inner);
      v.setUint32(7, 1780000000, Endian.little);
      inner[14] = 60;
      v.setFloat32(105, double.nan, Endian.little);
      final g = parseGen5Historical(inner) as Gen5HistorySample?;
      expect(g?.signalQualityLogVariance, isNull);
    });

    test('a good accel still decodes the whole record', () {
      final inner = Uint8List(kGen5V18InnerLen);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      final v = ByteData.sublistView(inner);
      v.setUint32(7, 1780000000, Endian.little);
      inner[14] = 102;
      v.setFloat32(33, 0.01, Endian.little);
      v.setFloat32(37, 0.0, Endian.little);
      v.setFloat32(41, 0.0, Endian.little);
      v.setFloat32(45, 1.0, Endian.little);
      v.setInt16(65, 3057, Endian.little);
      final g = parseGen5Historical(inner) as Gen5HistorySample?;
      expect(g, isNotNull);
      expect(g!.heartRate, 102);
      expect(g.skinTempC, closeTo(30.57, 0.01));
      expect(g.gravityG, hasLength(3));
    });
  });

  group('a corrupt length field does not swallow the stream', () {
    test('frames packed behind a bad length are recovered', () {
      // The length is covered only by the header check — 8 bits on gen4 — so
      // roughly 1 in 254 corrupt pairs still passes it. Consuming a length the
      // payload CRC32 disagrees with steps over every frame behind it, and the
      // band goes on to trim records that were never banked.
      final frames = [
        for (var i = 0; i < 6; i++)
          buildFrame(_record(version: 24)..[3] = i)
      ];
      final stream = <int>[for (final f in frames) ...f];

      final clean = FrameReassembler();
      expect(clean.feed(Uint8List.fromList(stream)).where((f) => f.valid),
          hasLength(6));

      // Corrupt the SECOND frame's payload so its CRC32 fails while its header
      // still parses — the header covers the length bytes, not the body.
      final corrupt = List<int>.from(stream);
      corrupt[frames[0].length + 10] ^= 0xFF;
      final got = FrameReassembler().feed(Uint8List.fromList(corrupt));
      expect(got.where((f) => f.valid), hasLength(5),
          reason: 'only the damaged frame is lost, not the four behind it');
    });
  });
}
