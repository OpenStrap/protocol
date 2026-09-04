// Envelope + battery decode for the Lefun-family OEM ring/band protocol.
//
// NOTHING HERE HAS MET HARDWARE. These fixtures are hand-built to the
// documented envelope shape, not captured off a device.

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  group('buildLefunFrame', () {
    test('a bare battery request', () {
      expect(
        buildLefunFrame(kLefunReportBattery),
        [0xAB, 0x04, 0x03, 0xEE],
      );
    });

    test('a request with arguments', () {
      expect(
        buildLefunFrame(kLefunReportFirmwareInfo),
        [0xAB, 0x04, 0x00, 0x0C],
      );
    });

    test('too long to fit one write throws', () {
      expect(
        () => buildLefunFrame(0x01, params: List.filled(20, 0)),
        throwsArgumentError,
      );
    });
  });

  group('parseLefunFrame', () {
    test('a battery reply round-trips', () {
      final frame = parseLefunFrame(const [0x5A, 0x05, 0x03, 0x57, 0xFB])!;
      expect(frame.report, kLefunReportBattery);
      expect(frame.params, [0x57]);
    });

    test('a zero battery reply round-trips', () {
      final frame = parseLefunFrame(const [0x5A, 0x05, 0x03, 0x00, 0xA3])!;
      expect(frame.params, [0x00]);
    });

    test('wrong marker byte is refused', () {
      expect(
        parseLefunFrame(const [0xAB, 0x05, 0x03, 0x57, 0xFB]),
        isNull,
      );
    });

    test('too short is refused', () {
      expect(parseLefunFrame(const [0x5A, 0x05, 0x03]), isNull);
      expect(parseLefunFrame(const []), isNull);
    });

    test('a declared length longer than the buffer is refused', () {
      expect(
        parseLefunFrame(const [0x5A, 0x06, 0x03, 0x57]),
        isNull,
      );
    });

    test('a corrupted checksum is refused', () {
      expect(
        parseLefunFrame(const [0x5A, 0x05, 0x03, 0x57, 0x00]),
        isNull,
      );
    });
  });

  group('decodeLefunBattery', () {
    test('a mid-range level', () {
      expect(decodeLefunBattery(const [87]), 87);
    });

    test('zero is valid', () {
      expect(decodeLefunBattery(const [0]), 0);
    });

    test('full charge is valid', () {
      expect(decodeLefunBattery(const [100]), 100);
    });

    test('out of range is refused, not clamped', () {
      expect(decodeLefunBattery(const [101]), isNull);
    });

    test('wrong argument count is refused', () {
      expect(decodeLefunBattery(const []), isNull);
      expect(decodeLefunBattery(const [1, 2]), isNull);
    });
  });
}
