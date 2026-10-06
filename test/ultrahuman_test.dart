// The Ultrahuman Ring Air wire format, against constructed fixtures.
//
// UNLIKE `oura_test.dart`, THESE BYTES ARE NOT A CAPTURE. Nobody on this
// project owns a ring, so there is no real notification to pin against — the
// fixtures below are built BY HAND to the documented byte layout and exist to
// pin THIS FILE'S decoder against that documented layout, not to assert the
// layout is correct. See `ultrahuman.dart`'s own header for what is and is not
// claimed.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _u32le(int v) => Uint8List.fromList(
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
Uint8List _u16le(int v) => Uint8List.fromList([v & 0xff, (v >> 8) & 0xff]);
Uint8List _f32le(double v) {
  final b = ByteData(4)..setFloat32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

/// One 32-byte record, built field-by-field from the layout in
/// `ultrahuman.dart`.
List<int> _record({
  int tsA = 1700000000,
  int hr = 58,
  int hrv = 42,
  int spo2 = 97,
  int hrQuality = kUltrahumanHrQualityLegacy,
  int tsB = 1700000000,
  double skinTempC = 34.5,
  double ambientTempC = 26.0,
  int tsC = 1700000000,
  int activity = 12,
  int steps = 30,
  int hrvSdnn = 20,
  int tempQuality = 3,
  int index = 0x1234,
}) =>
    <int>[
      ..._u32le(tsA),
      hr,
      hrv,
      spo2,
      hrQuality,
      ..._u32le(tsB),
      ..._f32le(skinTempC),
      ..._f32le(ambientTempC),
      ..._u32le(tsC),
      ..._u16le(activity),
      ..._u16le(steps),
      hrvSdnn,
      tempQuality,
      ..._u16le(index),
    ];

void main() {
  group('outbound frames — opcode plus body, no envelope', () {
    test('set time is a bare u32-LE unix second', () {
      expect(ultrahumanCmdSetTime(1700000000),
          [0x02, ..._u32le(1700000000)]);
    });

    test('get time, get earliest and get latest carry no body', () {
      expect(ultrahumanCmdGetTime(), [0x05]);
      expect(ultrahumanCmdGetEarliestIndex(), [0x07]);
      expect(ultrahumanCmdGetLatestIndex(), [0x08]);
    });

    test('get recordings is a u16-LE start index', () {
      expect(ultrahumanCmdGetRecordings(300), [0x04, ..._u16le(300)]);
    });

    test('out-of-range values are rejected, not silently truncated', () {
      expect(() => ultrahumanCmdGetRecordings(-1), throwsRangeError);
      expect(() => ultrahumanCmdGetRecordings(0x10000), throwsRangeError);
      expect(() => ultrahumanCmdSetTime(-1), throwsRangeError);
      expect(() => ultrahumanCmdSetTime(0x100000000), throwsRangeError);
    });
  });

  group('response framing', () {
    test('opcode, result, count, payload, then a 2-byte trailer', () {
      final rec = _record();
      final value = <int>[0x04, 0x00, 1, ...rec, 0xaa, 0xbb];
      final r = parseUltrahumanResponse(value)!;
      expect(r.opcode, 0x04);
      expect(r.result, 0x00);
      expect(r.ok, isTrue);
      expect(r.count, 1);
      expect(r.payload, rec);
      expect(r.trailer, [0xaa, 0xbb]);
    });

    test('a zero-payload response is still framed (get-index replies)', () {
      final value = <int>[0x08, 0x00, 0, 0xaa, 0xbb];
      final r = parseUltrahumanResponse(value)!;
      expect(r.payload, isEmpty);
      expect(r.trailer, [0xaa, 0xbb]);
    });

    test('result 0xee means empty, 0xff means fail', () {
      expect(parseUltrahumanResponse([0x04, 0xee, 0, 0, 0])!.empty, isTrue);
      expect(parseUltrahumanResponse([0x04, 0xff, 0, 0, 0])!.ok, isFalse);
    });

    test('shorter than the 5-byte floor is refused, not read out of bounds',
        () {
      expect(parseUltrahumanResponse([0x04, 0x00, 0, 0]), isNull);
      expect(parseUltrahumanResponse(const []), isNull);
    });

    test(
        'an ok 0x04 reply whose count byte does not match its payload still '
        'yields every whole record, and never the trailer', () {
      final rec = _record(tsA: 7);
      final r = parseUltrahumanResponse(
          <int>[0x04, 0x00, 3, ...rec, 0x11, 0x22, 0xaa, 0xbb])!;
      expect(r.ok, isTrue);
      expect(r.trailer, [0xaa, 0xbb]);
      expect(parseUltrahumanRecords(r.payload).map((x) => x.tsA), [7]);
    });

    test('every result other than ok and empty is a failure', () {
      for (final code in [0x03, 0x05, 0x07, 0x0a, 0xff]) {
        expect(parseUltrahumanResponse([0x04, code, 0, 0, 0])!.failed, isTrue,
            reason: 'result 0x${code.toRadixString(16)}');
      }
      expect(parseUltrahumanResponse([0x04, 0xee, 0, 0, 0])!.failed, isFalse);
      expect(parseUltrahumanResponse([0x04, 0x00, 0, 0, 0])!.failed, isFalse);
    });

    test('a fail/empty result is still framed even if count looks off', () {
      // Result byte governs these, not count/payload agreement.
      expect(parseUltrahumanResponse([0x04, 0xff, 9, 0xaa, 0xbb]), isNotNull);
      expect(parseUltrahumanResponse([0x04, 0xee, 9, 0xaa, 0xbb]), isNotNull);
    });
  });

  group('the 32-byte record', () {
    test('a record is exactly 32 bytes and ends with its own index', () {
      final bytes = _record();
      expect(bytes.length, kUltrahumanRecordLen);
      final r = parseUltrahumanRecord(bytes, 0)!;
      expect(r.index, 0x1234);
    });

    test('activity is a u16 across bytes 24-25; byte 28 is SDNN, unscaled',
        () {
      final r = parseUltrahumanRecord(
          _record(activity: 0x0302, hrvSdnn: 255, tempQuality: 9), 0)!;
      expect(r.activity, 0x0302);
      expect(r.hrvSdnn, 255);
      expect(r.tempQuality, 9);
    });

    test('bytes 12-15 are skin temperature, 16-19 the ambient sensor', () {
      final r = parseUltrahumanRecord(
          _record(skinTempC: 35.25, ambientTempC: 21.5), 0)!;
      expect(r.skinTempC, 35.25);
      expect(r.ambientTempC, 21.5);
    });

    test('only contact-class quality values are valid readings', () {
      for (final q in [0, 1, 5, 6, 7, 9, 11]) {
        expect(ultrahumanHrQualityValid(q), isTrue, reason: '$q');
      }
      for (final q in [2, 10, 14, 15, 100, 110, 150, 151]) {
        expect(ultrahumanHrQualityValid(q), isFalse, reason: '$q');
      }
    });

    test('every field lands at its documented offset', () {
      final bytes = _record(
        tsA: 1700000001,
        hr: 61,
        hrv: 45,
        spo2: 98,
        hrQuality: kUltrahumanHrQualityCdtHr,
        tsB: 1700000002,
        skinTempC: 35.1,
        ambientTempC: 24.0,
        tsC: 1700000003,
        activity: 88,
        steps: 12,
        hrvSdnn: 40,
      );
      final r = parseUltrahumanRecord(bytes, 0)!;
      expect(r.tsA, 1700000001);
      expect(r.hr, 61);
      expect(r.hrv, 45);
      expect(r.spo2, 98);
      expect(r.hrQuality, kUltrahumanHrQualityCdtHr);
      expect(r.tsB, 1700000002);
      expect(r.skinTempC, closeTo(35.1, 1e-4));
      expect(r.ambientTempC, closeTo(24.0, 1e-4));
      expect(r.tsC, 1700000003);
      expect(r.activity, 88);
      expect(r.steps, 12);
      expect(r.hrvSdnn, 40);
    });

    test('the three timestamps are independent, not collapsed to one', () {
      final bytes = _record(tsA: 100, tsB: 200, tsC: 300);
      final r = parseUltrahumanRecord(bytes, 0)!;
      expect((r.tsA, r.tsB, r.tsC), (100, 200, 300));
    });

    test('0 bpm / 0 SpO2 are transcribed, not reinterpreted as null', () {
      final bytes = _record(hr: 0, spo2: 0);
      final r = parseUltrahumanRecord(bytes, 0)!;
      expect(r.hr, 0);
      expect(r.spo2, 0);
    });

    test('a record read past the end of the buffer is refused', () {
      final bytes = _record();
      expect(parseUltrahumanRecord(bytes, 1), isNull);
      expect(parseUltrahumanRecord(bytes, -1), isNull);
    });

    test('offset finds the second record inside a two-record payload', () {
      final payload = <int>[..._record(tsA: 1), ..._record(tsA: 2)];
      final r = parseUltrahumanRecord(payload, kUltrahumanRecordLen)!;
      expect(r.tsA, 2);
    });
  });

  group('parseUltrahumanRecords — a whole batch', () {
    test('unpacks every record in a payload, in order', () {
      final payload = Uint8List.fromList(
          [..._record(tsA: 1), ..._record(tsA: 2), ..._record(tsA: 3)]);
      final rs = parseUltrahumanRecords(payload);
      expect(rs.map((r) => r.tsA), [1, 2, 3]);
    });

    test('a trailing partial record is ignored, not read out of bounds', () {
      final payload =
          Uint8List.fromList([..._record(tsA: 1), 0x01, 0x02, 0x03]);
      final rs = parseUltrahumanRecords(payload);
      expect(rs.map((r) => r.tsA), [1]);
    });

    test('an empty payload decodes to no records', () {
      expect(parseUltrahumanRecords(Uint8List(0)), isEmpty);
    });
  });
}
