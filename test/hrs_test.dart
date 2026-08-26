// The Bluetooth SIG Heart Rate Measurement (0x2A37) decoder — any standard
// chest strap or optical armband, not one vendor's device.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a strap, so these
// fixtures are built from the Bluetooth SIG's Heart Rate Service 1.0
// characteristic layout, not captured off a device. They pin the decode; they
// do not prove any real strap behaves this way.

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Frames as the three common flag shapes put them on the wire.
///
/// The RR-Interval flag (bit 4) is OPTIONAL in the spec, and [kBpmOnly] is the
/// case that matters most: plenty of optical armbands never set it, and the
/// parser has to degrade to "HR, no beats" rather than assume beats are there.
const List<int> kBpmOnly = <int>[0x00, 61]; // flags 0x00 — RR bit CLEAR
const List<int> kBpmOnlyWithContact = <int>[0x06, 61]; // contact reported

void main() {
  test('uint8 HR, no RR', () {
    final s = parseHeartRateMeasurement([0x00, 72])!;
    expect(s.hr, 72);
    expect(s.rrMs, isEmpty);
    expect(s.contact, isNull); // contact not supported → absent, not "false"
  });

  test('the RR bit CLEAR is a strap with no beats, not a strap with zero', () {
    final s = parseHeartRateMeasurement(kBpmOnly)!;
    expect(s.hr, 61);
    expect(s.rrMs, isEmpty);
    expect(parseHeartRateMeasurement(kBpmOnlyWithContact)!.contact, isTrue);
  });

  test('uint16 HR reads little-endian', () {
    final s = parseHeartRateMeasurement([0x01, 0x2C, 0x01])!; // 300
    expect(s.hr, 300);
  });

  test('RR intervals convert from 1/1024 s to ms', () {
    // 1024 ticks = 1000 ms; 512 = 500 ms.
    final s = parseHeartRateMeasurement([0x10, 60, 0x00, 0x04, 0x00, 0x02])!;
    expect(s.rrMs, [1000, 500]);
  });

  test('energy-expended field is skipped, not read as an RR interval', () {
    // flags 0x18 = RR present + energy expended present. The 2-byte energy
    // field sits BETWEEN hr and the RR list; reading it as RR is the classic
    // bug and would yield a bogus first interval.
    final s = parseHeartRateMeasurement([
      0x18, 60, //
      0xE8, 0x03, // energy expended = 1000 kJ
      0x00, 0x04, // RR = 1024 ticks = 1000 ms
    ])!;
    expect(s.rrMs, [1000]);
  });

  test('contact bits: reported false is distinguishable from unsupported', () {
    expect(parseHeartRateMeasurement([0x04, 60])!.contact, isFalse); // 0b10
    expect(parseHeartRateMeasurement([0x06, 60])!.contact, isTrue); // 0b11
    expect(parseHeartRateMeasurement([0x02, 60])!.contact, isNull); // 0b01
  });

  test('implausible beat intervals are dropped, not clamped', () {
    // 8 ticks ≈ 8 ms and 4096 ticks = 4 s: neither is a beat. A clamped value
    // would be a fabricated one.
    final s = parseHeartRateMeasurement([
      0x10, 60, //
      0x08, 0x00, // 8 ms
      0x00, 0x10, // 4000 ms
      0x00, 0x04, // 1000 ms — the only real one
    ])!;
    expect(s.rrMs, [1000]);
  });

  test('a searching sensor reporting 0 bpm is not a measurement', () {
    expect(parseHeartRateMeasurement([0x00, 0]), isNull);
  });

  test('truncated values are dropped rather than patched up', () {
    expect(parseHeartRateMeasurement([0x00]), isNull);
    expect(parseHeartRateMeasurement([]), isNull);
    expect(parseHeartRateMeasurement([0x01, 0x48]), isNull); // uint16, 1 byte
  });

  test('a trailing odd byte refuses the notification, never reads past it',
      () {
    // The RR field is a run of uint16 LE ticks; an odd-length remainder means
    // the buffer ends mid-field, which puts every earlier offset in doubt
    // too. Refuse the whole notification rather than silently keep what
    // parsed before the truncation.
    expect(parseHeartRateMeasurement([0x10, 60, 0x00, 0x04, 0x7F]), isNull);
  });

  test('a truncated Energy Expended field refuses the notification', () {
    // Flag bit 3 set (energy present) but only one byte follows HR — the
    // field is declared 2 bytes wide unconditionally once the bit is set.
    expect(parseHeartRateMeasurement([0x08, 60, 0x01]), isNull);
  });
}
