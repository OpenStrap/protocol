// gen5 (WHOOP 5 / "fd4b") multi-band framing + record tests.
//
// Test vectors are synthetic or self-derived: the canonical gen5 client-HELLO
// frame is the value independently documented in our own PROTOCOL_FINDINGS.md,
// and the record vectors are hand-built to exercise the confirmed offsets.

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _hex(String s) {
  final clean = s.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('crc16Modbus', () {
    test('gen5 hello header → 0x71E6', () {
      // header bytes aa 01 08 00 00 01 → crc16-modbus 0x71E6 (LE e6 71).
      expect(crc16Modbus([0xaa, 0x01, 0x08, 0x00, 0x00, 0x01]), 0x71E6);
    });
    test('empty input is the init value', () {
      expect(crc16Modbus(const []), 0xFFFF);
    });
  });

  group('BandProfile', () {
    test('gen4/gen5 header shapes', () {
      expect(BandProfile.gen4.headerLen, 4);
      expect(BandProfile.gen4.sizeFieldOffset, 1);
      expect(BandProfile.gen5.headerLen, 8);
      expect(BandProfile.gen5.sizeFieldOffset, 2);
      expect(BandProfile.of(DeviceType.gen5).isGen5, isTrue);
      expect(BandProfile.of(DeviceType.gen4).isGen5, isFalse);
    });
    test('GATT prefixes differ, low nibble shared', () {
      expect(GattProfile.gen4.servicePrefix, '61080001');
      expect(GattProfile.gen5.servicePrefix, 'fd4b0001');
      expect(GattProfile.gen5.cmdTo.startsWith('fd4b0002'), isTrue);
      expect(GattProfile.gen5.data.startsWith('fd4b0005'), isTrue);
    });
  });

  group('gen5 client HELLO', () {
    test('reproduces the canonical 16-byte frame byte-for-byte', () {
      // Canonical gen5 CLIENT_HELLO (GET_HELLO 0x91), per PROTOCOL_FINDINGS.md.
      // Asserting equality validates crc16-modbus (header) + crc32 (payload) +
      // the gen5 header layout all at once.
      final expected = _hex('aa0108000001e67123019101363e5c8d');
      expect(gen5ClientHello(), expected);
    });
  });

  group('gen5 framing round-trip', () {
    test('buildFrame(gen5) → parseFrame(gen5) preserves inner + both CRCs', () {
      final inner = <int>[0x2f, 24, 0, 1, 0, 0, 0, 0xaa, 0xbb, 0, 0, 0, 0, 55];
      final frame = buildFrame(inner, profile: BandProfile.gen5);
      expect(frame[0], 0xAA);
      expect(frame[1], 0x01); // gen5 fixed header byte
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.headerCrcOk, isTrue);
      expect(parsed.crc32Ok, isTrue);
      expect(parsed.valid, isTrue);
      // inner is padded to /4; the leading bytes must survive verbatim.
      expect(parsed.inner.sublist(0, inner.length), Uint8List.fromList(inner));
    });

    test('a corrupted gen5 header CRC is flagged', () {
      final frame = buildFrame(const [0x2f, 24, 0, 1], profile: BandProfile.gen5);
      frame[6] ^= 0xFF; // trash the crc16 low byte
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.headerCrcOk, isFalse);
    });
  });

  group('gen4 regression (default profile unchanged)', () {
    test('default buildFrame is still the 4-byte gen4 envelope', () {
      final a = buildFrame(const [0x23, 0, 0x0b]);
      final b = buildFrame(const [0x23, 0, 0x0b], profile: BandProfile.gen4);
      expect(a, b);
      expect(a[0], 0xAA);
      final parsed = parseFrame(a)!; // default gen4
      expect(parsed.valid, isTrue);
    });
  });

  group('FrameReassembler(gen5)', () {
    test('carves two concatenated gen5 frames + waits for a partial', () {
      final f1 = buildFrame(const [0x2f, 24, 0, 1, 0, 0, 0], profile: BandProfile.gen5);
      final f2 = buildFrame(const [0x2f, 24, 0, 2, 0, 0, 0], profile: BandProfile.gen5);
      final ra = FrameReassembler(profile: BandProfile.gen5);
      final combined = <int>[...f1, ...f2.sublist(0, 5)]; // f2 arrives partial
      final got = ra.feed(combined);
      expect(got.length, 1); // only f1 is complete
      expect(got.first.valid, isTrue);
      final rest = ra.feed(f2.sublist(5)); // deliver the remainder
      expect(rest.length, 1);
      expect(rest.first.valid, isTrue);
    });
  });

  group('gen5 history ACK (safe-trim token echo)', () {
    test('buildHistoryResultOk(gen5) is a valid frame echoing the verbatim token', () {
      final token = <int>[0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04];
      final ack = buildHistoryResultOk(7, token, profile: BandProfile.gen5);
      final parsed = parseFrame(ack, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue); // both gen5 CRCs must check out
      // inner = [0x23 COMMAND][seq][0x17 HISTORICAL_DATA_RESULT][0x01][token…]
      expect(parsed.inner[2], 0x17);
      expect(parsed.inner[3], 0x01);
      expect(parsed.inner.sublist(4, 12), Uint8List.fromList(token));
    });
    test('rejects a non-8-byte token', () {
      expect(
        () => buildHistoryResultOk(1, const [0, 0, 0], profile: BandProfile.gen5),
        throwsArgumentError,
      );
    });
  });

  group('parseGen5Record (thin K24)', () {
    Uint8List k24({required int version, required int hr, int counter = 7, int ts = 1779000000}) {
      final inner = Uint8List(80);
      inner[0] = 0x2f;
      inner[1] = version;
      inner[2] = 0;
      final v = ByteData.sublistView(inner);
      v.setUint32(3, counter, Endian.little);
      v.setUint32(7, ts, Endian.little);
      inner[17] = hr;
      return inner;
    }

    test('decodes HR + timing, leaves everything else empty', () {
      final r = parseGen5Record(k24(version: 24, hr: 51))!;
      expect(r.histVersion, 24);
      expect(r.hr, 51);
      expect(r.counter, 7);
      expect(r.tsEpoch, 1779000000);
      expect(r.accelG, isEmpty); // no 1 Hz accel on gen5
      expect(r.rrIntervalsMs, isEmpty); // RR not sourced from K24
      expect(r.skinTempRaw, 0); // temp comes from the TEMPERATURE_LEVEL event
      expect(r.spo2RedRaw, 0);
    });

    test('keeps a warming-device HR of 0', () {
      expect(parseGen5Record(k24(version: 24, hr: 0))!.hr, 0);
    });

    test('rejects an implausible HR (→ archived by caller)', () {
      expect(parseGen5Record(k24(version: 24, hr: 240)), isNull);
    });

    test('returns null for a non-normal-history version (e.g. K10 motion)', () {
      expect(parseGen5Record(k24(version: 10, hr: 60)), isNull);
    });

    test('accepts the K9/K12 thin-history variants', () {
      expect(parseGen5Record(k24(version: 9, hr: 60))!.hr, 60);
      expect(parseGen5Record(k24(version: 12, hr: 60))!.hr, 60);
    });
  });
}
