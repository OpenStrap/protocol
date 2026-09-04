import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('O2Ring frame envelope', () {
    test('builds the published, hardware-captured 0x17 request byte-exact', () {
      // AA 17 E8 00 00 00 00 1B — an independently published request for
      // this ring family, captured off real hardware. This is the one
      // external fact this module is checked against.
      expect(
        buildO2RingCommand(0x17),
        equals(<int>[0xAA, 0x17, 0xE8, 0x00, 0x00, 0x00, 0x00, 0x1B]),
      );
    });

    test('round-trips a command with a payload through parse', () {
      final built = buildO2RingCommand(0x14, block: 7, data: [1, 2, 3]);
      final f = parseO2RingFrame(built);
      expect(f, isNotNull);
      expect(f!.cmd, 0x14);
      expect(f.block, 7);
      expect(f.data, equals([1, 2, 3]));
    });

    test('refuses a bad header marker', () {
      final built = buildO2RingCommand(0x14)..[0] = 0xAB;
      expect(parseO2RingFrame(built), isNull);
    });

    test('refuses a mismatched cmd/cmd-xor pair', () {
      final built = buildO2RingCommand(0x14)..[2] = 0x00;
      expect(parseO2RingFrame(built), isNull);
    });

    test('refuses a flipped data byte (CRC catches it)', () {
      final built = buildO2RingCommand(0x14, data: [0x55]);
      built[7] ^= 0xFF;
      expect(parseO2RingFrame(built), isNull);
    });

    test('refuses a declared length longer than the buffer', () {
      final built = buildO2RingCommand(0x14, data: [1, 2, 3]);
      final truncated = built.sublist(0, built.length - 2);
      expect(parseO2RingFrame(truncated), isNull);
    });

    test('refuses a buffer shorter than the minimum frame', () {
      expect(parseO2RingFrame([0xAA, 0x14, 0xEB]), isNull);
    });
  });

  group('INFO reply', () {
    test('decodes battery, model, serial and the file list', () {
      const json = '{"CurBAT":"75%","FileList":'
          '"20260116233312.vld,20260115221045.vld",'
          '"Model":"O2Ring","SN":"ABC123"}';
      final info = parseO2RingInfo(json.codeUnits);
      expect(info, isNotNull);
      expect(info!.batteryPct, 75);
      expect(info.model, 'O2Ring');
      expect(info.serial, 'ABC123');
      expect(info.files, equals([
        '20260116233312.vld',
        '20260115221045.vld',
      ]));
    });

    test('an empty file list decodes to no files, not one blank entry', () {
      const json = '{"CurBAT":"50%","FileList":"","Model":"O2Ring","SN":"X"}';
      expect(parseO2RingInfo(json.codeUnits)!.files, isEmpty);
    });

    test('a numeric battery is accepted, not just a percent string', () {
      const json = '{"CurBAT":75,"FileList":"","Model":"O2Ring","SN":"X"}';
      expect(parseO2RingInfo(json.codeUnits)!.batteryPct, 75);
    });

    test('a non-string Model or SN falls back to null, never throws', () {
      const json = '{"CurBAT":"75%","FileList":"","Model":123,"SN":false}';
      final info = parseO2RingInfo(json.codeUnits);
      expect(info, isNotNull);
      expect(info!.model, isNull);
      expect(info.serial, isNull);
      // The rest of the object still decodes — one bad field does not sink
      // the whole reply.
      expect(info.batteryPct, 75);
    });

    test('refuses non-JSON rather than guessing at fields', () {
      expect(parseO2RingInfo([0xAA, 0x14, 0x00]), isNull);
    });

    test('refuses a JSON value that is not an object', () {
      expect(parseO2RingInfo('[1,2,3]'.codeUnits), isNull);
    });
  });
}
