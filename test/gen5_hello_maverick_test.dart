// Gen5HelloInfo.isMaverick — the WHOOP MG identity gate. Official 5.458.0
// maps optical revision [0,38) to app generation MAVERICK and [48,86) to
// GOOSE (ordinary WHOOP 5.0); the physical MG returns 0, the retained
// ordinary 5.0 returns 82. Only a revision-1 HELLO may be read this way.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

Gen5HelloInfo hello({int revision = 1, required int optical}) {
  final body = Uint8List(Gen5HelloInfo.semanticBodyLen);
  body[0] = revision;
  final v = ByteData.sublistView(body);
  v.setUint32(1, 900, Endian.little); // battery raw 90.0%
  v.setUint32(6, 1787822694, Endian.little);
  for (var i = 0; i < 10; i++) {
    // Synthetic: the serial is 10 ASCII bytes at offset 14 and no assertion
    // here depends on which strap it names.
    body[14 + i] = '5AM0000000'.codeUnitAt(i);
  }
  v.setUint32(79, 13, Endian.little); // hardware family
  v.setUint32(87, optical, Endian.little);
  body[91] = 50;
  body[92] = 41;
  body[93] = 1;
  return Gen5HelloInfo.parse(body)!;
}

void main() {
  test('the physical MG (optical 0) is MAVERICK and not WHOOP 5', () {
    final h = hello(optical: 0);
    expect(h.isMaverick, isTrue);
    expect(h.isWhoop5, isFalse);
    expect(h.serial, '5AM0000000');
    expect(h.firmwareVersion, '50.41.1.0');
  });

  test('the interval is [0, 38): 37 is in, 38 is out', () {
    expect(hello(optical: 37).isMaverick, isTrue);
    expect(hello(optical: 38).isMaverick, isFalse);
    expect(hello(optical: 47).isMaverick, isFalse);
  });

  test('the ordinary WHOOP 5.0 (optical 82) is WHOOP 5, never MAVERICK', () {
    final h = hello(optical: 82);
    expect(h.isMaverick, isFalse);
    expect(h.isWhoop5, isTrue);
    expect(hello(optical: 48).isMaverick, isFalse);
  });

  test('an unknown HELLO revision is never read through revision-1 offsets',
      () {
    expect(hello(revision: 2, optical: 0).isMaverick, isFalse);
    expect(hello(revision: 0, optical: 0).isMaverick, isFalse);
    // isWhoop5's existing behaviour is untouched by the new gate.
    expect(hello(revision: 2, optical: 82).isWhoop5, isTrue);
  });
}
