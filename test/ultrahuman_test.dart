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

/// One 32-byte record, built field-by-field from the documented offsets.
/// The documented table only fills 30 of the 32 bytes (see `ultrahuman.dart`);
/// the trailing 2 are padding this fixture supplies to reach the real record
/// length, and the decoder never reads them.
List<int> _record({
  int tsA = 1700000000,
  int hr = 58,
  int hrv = 42,
  int spo2 = 97,
  int measurementType = 1,
  int tsB = 1700000000,
  double maxSkinTempC = 34.5,
  double minSkinTempC = 33.8,
  int tsC = 1700000000,
  int activityLevel = 12,
  int steps = 30,
  int stress = 20,
}) =>
    <int>[
      ..._u32le(tsA),
      hr,
      hrv,
      spo2,
      measurementType,
      ..._u32le(tsB),
      ..._f32le(maxSkinTempC),
      ..._f32le(minSkinTempC),
      ..._u32le(tsC),
      ..._u16le(activityLevel),
      ..._u16le(steps),
      ..._u16le(stress),
      0x00, 0x00, // bytes 30-31 — undocumented, not read by the decoder
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
  });

  group('the 32-byte record', () {
    test('a record is exactly 32 bytes, 2 more than the documented fields '
        'fill, and those 2 are not read', () {
      final bytes = _record();
      expect(bytes.length, kUltrahumanRecordLen);
      final r = parseUltrahumanRecord(bytes, 0)!;
      expect(r.stress, 20); // the last documented field, at offset 28-29
    });

    test('every field lands at its documented offset', () {
      final bytes = _record(
        tsA: 1700000001,
        hr: 61,
        hrv: 45,
        spo2: 98,
        measurementType: kUltrahumanMeasureExercise,
        tsB: 1700000002,
        maxSkinTempC: 35.1,
        minSkinTempC: 34.0,
        tsC: 1700000003,
        activityLevel: 88,
        steps: 12,
        stress: 40,
      );
      final r = parseUltrahumanRecord(bytes, 0)!;
      expect(r.tsA, 1700000001);
      expect(r.hr, 61);
      expect(r.hrv, 45);
      expect(r.spo2, 98);
      expect(r.measurementType, kUltrahumanMeasureExercise);
      expect(r.tsB, 1700000002);
      expect(r.maxSkinTempC, closeTo(35.1, 1e-4));
      expect(r.minSkinTempC, closeTo(34.0, 1e-4));
      expect(r.tsC, 1700000003);
      expect(r.activityLevel, 88);
      expect(r.steps, 12);
      expect(r.stress, 40);
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
