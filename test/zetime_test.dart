// MyKronoz ZeTime's command envelope — pinned against the documented wire
// layout, not against a captured device: nobody on this project owns one.

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  test('battery request frame is the fixed 7-byte shape', () {
    expect(
      zetimeRequestFrame(kZeTimeCmdBattery),
      <int>[0x6f, 0x08, 0x70, 0x01, 0x00, 0x00, 0x8f],
    );
  });

  test('parses a battery reply and reads its level', () {
    // [preamble][cmd][action][lenLo][lenHi][level][end] — one payload byte,
    // so the declared length is 1 + 6 = 7 total.
    final f = parseZeTimeFrame([0x6f, 0x08, 0x01, 0x01, 0x00, 63, 0x8f])!;
    expect(f.cmd, kZeTimeCmdBattery);
    expect(f.payload, [63]);
    expect(zetimeBatteryLevel(f), 63);
  });

  test('refuses a level byte above 100 — not a real percentage', () {
    final f = parseZeTimeFrame([0x6f, 0x08, 0x01, 0x01, 0x00, 200, 0x8f])!;
    expect(zetimeBatteryLevel(f), isNull);
  });

  test('a non-battery frame has no battery level', () {
    final f = parseZeTimeFrame([0x6f, 0x02, 0x01, 0x01, 0x00, 9, 0x8f])!;
    expect(zetimeBatteryLevel(f), isNull);
  });

  test('refuses a short buffer', () {
    expect(parseZeTimeFrame([0x6f, 0x08, 0x01, 0x01, 0x00]), isNull);
  });

  test('refuses a missing preamble', () {
    expect(parseZeTimeFrame([0x00, 0x08, 0x01, 0x01, 0x00, 63, 0x8f]), isNull);
  });

  test('refuses a zero-length declaration', () {
    expect(parseZeTimeFrame([0x6f, 0x08, 0x01, 0x00, 0x00, 0x8f]), isNull);
  });

  test('refuses a declared length that does not match the buffer', () {
    // Declares a 2-byte payload but only 1 arrived.
    expect(parseZeTimeFrame([0x6f, 0x08, 0x01, 0x02, 0x00, 63, 0x8f]), isNull);
  });

  test('refuses a missing end marker', () {
    expect(parseZeTimeFrame([0x6f, 0x08, 0x01, 0x01, 0x00, 63, 0x00]), isNull);
  });
}
