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

  group('a gen5 v18 with an unusable accel is archived, not fabricated', () {
    test('the record is declined so nothing writes a zeroed gravity vector', () {
      // Keeping the second and reporting only the accel as absent is the right
      // shape, but it does not survive storage: decoded_onehz's ax/ay/az are
      // REAL NOT NULL, so absent becomes exact (0,0,0), and zAngle(0,0,0) is
      // 0.0 rather than NaN — a run of those reads as a perfectly still wrist
      // in four consumers that never consult the absent-marker. Declining sends
      // the record to raw_archive with its bytes intact instead, so it can be
      // re-decoded once the columns are nullable.
      final inner = Uint8List(kGen5V18InnerLen);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      final v = ByteData.sublistView(inner);
      v.setUint32(7, 1780000000, Endian.little);
      inner[14] = 102;
      v.setFloat32(33, 0.01, Endian.little);
      v.setFloat32(37, 40.0, Endian.little); // gravity far out of window
      v.setFloat32(41, 40.0, Endian.little);
      v.setFloat32(45, 40.0, Endian.little);
      expect(parseGen5Historical(inner), isNull);

      // A non-finite dynamic-accel word is declined for the same reason.
      final nan = Uint8List.fromList(inner);
      final nv = ByteData.sublistView(nan);
      nv.setFloat32(33, double.nan, Endian.little);
      nv.setFloat32(37, 0.0, Endian.little);
      nv.setFloat32(41, 0.0, Endian.little);
      nv.setFloat32(45, 1.0, Endian.little);
      expect(parseGen5Historical(nan), isNull);
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
