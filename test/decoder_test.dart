// Port of ts/test_decoder.ts: record-0 hard assertions + all 550 records decode.
// Also covers dart_header.json (550 R24 header cases).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('whoop_hist.jsonl golden fixture (550 records)', () {
    late List<Map<String, dynamic>> records;

    setUpAll(() {
      final candidates = ['../whoop_hist.jsonl', 'whoop_hist.jsonl'];
      File? f;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          f = File(c);
          break;
        }
      }
      if (f == null) {
        throw StateError(
            'whoop_hist.jsonl fixture not found (looked in $candidates)');
      }
      records = f
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .map((l) => json.decode(l) as Map<String, dynamic>)
          .toList();
    });

    test('loaded 550 records', () {
      expect(records.length, 550);
    });

    test('record 0 matches the oracle exactly', () {
      final r = parseR24(hexToBytes(records[0]['hex'] as String))!;
      expect(r.hr, 98);
      expect(r.tsEpoch, 1775395266);
      expect(r.rrCount, greaterThanOrEqualTo(0));
      expect(r.rrCount, lessThanOrEqualTo(4));
      expect(r.rrIntervalsMs.length, lessThanOrEqualTo(r.rrCount));
      // accel ≈ (-0.150, -0.331, 1.001)
      expect((r.accelG[0] - -0.150).abs() < 0.001, isTrue);
      expect((r.accelG[1] - -0.331).abs() < 0.001, isTrue);
      expect((r.accelG[2] - 1.001).abs() < 0.001, isTrue);
    });

    test('v24 optical offsets are inner-relative, not frame-absolute', () {
      final r = parseR24(hexToBytes(records[0]['hex'] as String))!;
      final b = hexToBytes(records[0]['hex'] as String);
      final view = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);

      // `parseR24` consumes the inner record starting at packet type 0x2f.
      // So the WHOOP 4 v24 optical block documented at frame[68/70/72/74]
      // is read here at inner[64/66/68/70].
      expect(r.spo2RedRaw, view.getUint16(64, Endian.little));
      expect(r.spo2IrRaw, view.getUint16(66, Endian.little));
      expect(r.skinTempRaw, view.getUint16(68, Endian.little));
      expect(r.ambientRaw, view.getUint16(70, Endian.little));
    });

    test('all 550 records decode without throwing / null', () {
      int ok = 0;
      for (final rec in records) {
        final r = parseR24(hexToBytes(rec['hex'] as String));
        if (r != null) ok++;
      }
      expect(ok, records.length);
    });
  });

  group('dart_header.json (550 R24 header cases)', () {
    test('counter/ts_epoch/ts_subsec/hr all match', () {
      final cases =
          json.decode(File('dart_header.json').readAsStringSync()) as List;
      expect(cases.length, 550);
      for (int i = 0; i < cases.length; i++) {
        final c = cases[i] as Map<String, dynamic>;
        final r = parseR24(hexToBytes(c['hex'] as String))!;
        expect(r.counter, c['counter'], reason: 'counter case $i');
        expect(r.tsEpoch, c['ts_epoch'], reason: 'ts_epoch case $i');
        expect(r.tsSubsec, c['ts_subsec'], reason: 'ts_subsec case $i');
        expect(r.hr, c['hr'], reason: 'hr case $i');
      }
    });
  });
}
