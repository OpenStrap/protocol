// The WearFit wire format, against real captured bytes: a documented
// find-watch request, a battery request/reply pair, and a device-info reply,
// each shown byte-for-byte in the family's own protocol notes. Nothing here
// was copied from anyone's decoder — the frame envelope is small enough that
// an independent read of the bytes is the whole of the proof.

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  group('WearFit framing', () {
    test('parses a real captured battery reply (not charging, 80%)', () {
      // AB 00 05 FF 91 80 00 50
      final f = parseWearFitFrame([0xab, 0x00, 0x05, 0xff, 0x91, 0x80, 0x00, 0x50]);
      expect(f, isNotNull);
      expect(f!.opcode, 0x91);
      expect(f.payload, [0x80, 0x00, 0x50]);
    });

    test('parses a real captured battery reply (charging, 80%)', () {
      // AB 00 05 FF 91 80 01 50
      final f = parseWearFitFrame([0xab, 0x00, 0x05, 0xff, 0x91, 0x80, 0x01, 0x50]);
      expect(f!.payload, [0x80, 0x01, 0x50]);
    });

    test('parses a real captured device-info reply', () {
      // AB 00 11 FF 92 C0 08 04 38 00 00 00 00 00 00 28 00 60 00 6B
      final f = parseWearFitFrame([
        0xab, 0x00, 0x11, 0xff, 0x92, //
        0xc0, 0x08, 0x04, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x60, 0x00, 0x6b,
      ]);
      expect(f, isNotNull);
      expect(f!.opcode, 0x92);
      expect(f.payload.length, 15); // len 0x11 - 2
    });

    test('rejects a frame missing the 0xFF marker', () {
      expect(parseWearFitFrame([0xab, 0x00, 0x05, 0x00, 0x91, 0x80, 0x00, 0x50]), isNull);
    });

    test('rejects a truncated frame', () {
      // declares len 5 (3 payload bytes) but only one is present
      expect(parseWearFitFrame([0xab, 0x00, 0x05, 0xff, 0x91, 0x80]), isNull);
    });

    test('rejects a length too short to carry an opcode-following byte', () {
      expect(parseWearFitFrame([0xab, 0x00, 0x01, 0xff, 0x91]), isNull);
    });

    test('rejects a frame with the wrong header byte', () {
      expect(parseWearFitFrame([0xac, 0x00, 0x05, 0xff, 0x91, 0x80, 0x00, 0x50]), isNull);
    });

    test('buildWearFitFrame round-trips through parseWearFitFrame', () {
      final built = buildWearFitFrame(0x71, const [0x80]);
      // AB 00 03 FF 71 80 — the real captured "find watch" request.
      expect(built, [0xab, 0x00, 0x03, 0xff, 0x71, 0x80]);
      final parsed = parseWearFitFrame(built);
      expect(parsed!.opcode, 0x71);
      expect(parsed.payload, [0x80]);
    });

    test('buildWearFitFrame with no payload', () {
      expect(buildWearFitFrame(0x20), [0xab, 0x00, 0x02, 0xff, 0x20]);
    });

    test('wearFitCmdGetBattery matches the real captured request', () {
      // AB 00 04 FF 91 80 01
      expect(wearFitCmdGetBattery(), [0xab, 0x00, 0x04, 0xff, 0x91, 0x80, 0x01]);
    });
  });

  group('WearFit battery', () {
    test('decodes not-charging at 80%', () {
      final f = parseWearFitFrame([0xab, 0x00, 0x05, 0xff, 0x91, 0x80, 0x00, 0x50])!;
      final b = parseWearFitBattery(f);
      expect(b, isNotNull);
      expect(b!.chargeState, 0);
      expect(b.percent, 80);
    });

    test('decodes fully-charged at 100%', () {
      // AB 00 05 FF 91 80 02 64
      final f = parseWearFitFrame([0xab, 0x00, 0x05, 0xff, 0x91, 0x80, 0x02, 0x64])!;
      final b = parseWearFitBattery(f);
      expect(b!.chargeState, 2);
      expect(b.percent, 100);
    });

    test('refuses a non-battery opcode', () {
      final f = parseWearFitFrame([0xab, 0x00, 0x03, 0xff, 0x71, 0x80])!;
      expect(parseWearFitBattery(f), isNull);
    });

    test('refuses a battery frame too short to carry a percent', () {
      final f = parseWearFitFrame([0xab, 0x00, 0x03, 0xff, 0x91, 0x80])!;
      expect(parseWearFitBattery(f), isNull);
    });

    test('refuses an implausible percent', () {
      final f = parseWearFitFrame([0xab, 0x00, 0x05, 0xff, 0x91, 0x80, 0x00, 0xc8])!;
      expect(parseWearFitBattery(f), isNull);
    });
  });
}
