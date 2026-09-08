// Labrador R16 (WHOOP MG raw ECG, historical type 47) — recognition and
// exact preservation only. The body is not source-closed; nothing here names
// a body byte. Synthetic fixtures.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

Uint8List r16Inner({
  int packetType = 0x2F,
  int revision = 16,
  int sequence = 23940915,
  int strapSeconds = 1787823731,
  int subseconds = 24242,
  int totalLen = LabradorR16Raw.observedInnerLen,
}) {
  final inner = Uint8List(totalLen);
  final v = ByteData.sublistView(inner);
  inner[0] = packetType;
  inner[1] = revision;
  inner[2] = 3; // physical secondary byte
  v.setUint32(3, sequence, Endian.little);
  v.setUint32(7, strapSeconds, Endian.little);
  v.setUint16(11, subseconds, Endian.little);
  for (var i = 13; i < totalLen; i++) {
    inner[i] = (i * 7 + 3) & 0xff; // arbitrary body, including 0xAA bytes
  }
  return inner;
}

void main() {
  test('a type-47 revision-16 record is recognised with its common header', () {
    final inner = r16Inner();
    final r = LabradorR16Raw.tryParse(inner)!;
    expect(r.sequence, 23940915);
    expect(r.strapSeconds, 1787823731);
    expect(r.subseconds, 24242);
    expect(r.strapTime, closeTo(1787823731 + 24242 / 32768.0, 1e-9));
    expect(r.inner, inner, reason: 'exact bytes preserved');
    expect(r.inner, hasLength(1572));
  });

  test('the inner is copied, not aliased', () {
    final inner = r16Inner();
    final r = LabradorR16Raw.tryParse(inner)!;
    inner[100] ^= 0xff;
    expect(r.inner[100], isNot(inner[100]));
  });

  test('other revisions and packet types are not R16', () {
    expect(LabradorR16Raw.tryParse(r16Inner(revision: 18)), isNull);
    expect(LabradorR16Raw.tryParse(r16Inner(revision: 17)), isNull);
    expect(LabradorR16Raw.tryParse(r16Inner(packetType: 0x2B)), isNull,
        reason: 'R16 never arrives live');
  });

  test('a record shorter than the common header is not recognised', () {
    final full = r16Inner();
    for (var len = 0; len < 13; len++) {
      expect(
          LabradorR16Raw.tryParse(Uint8List.sublistView(full, 0, len)), isNull,
          reason: 'length $len');
    }
    expect(
        LabradorR16Raw.tryParse(Uint8List.sublistView(full, 0, 13)), isNotNull);
  });

  test('tryParseFrame needs a decodable frame', () {
    final inner = r16Inner();
    final raw = buildFrame(inner, profile: BandProfile.gen5);
    expect(raw, hasLength(LabradorR16Raw.observedFrameLen));
    final f = parseFrame(raw, profile: BandProfile.gen5)!;
    expect(LabradorR16Raw.tryParseFrame(f), isNotNull);
    raw[8 + 500] ^= 0x01;
    final bad = parseFrame(raw, profile: BandProfile.gen5)!;
    expect(LabradorR16Raw.tryParseFrame(bad), isNull);
  });
}
