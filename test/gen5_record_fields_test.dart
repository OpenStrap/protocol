// gen5 record FIELD tests — the parts of v18/v20/v26 that were previously
// dropped, mis-paired or mislabelled: the flags byte and its PPG-rate bit, the
// per-record sub-second, the big-endian optical pair, the exact record
// lengths, and v20's block metadata.
//
// The v18/v26 frames below are the same REAL, CRC-verified captures used in
// gen5_historical_test.dart.

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

final _v18Frame = hex(
  'aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000'
  '000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000'
  '000000000000f7000901f10b0007010c020c000000000000000000000000000'
  '00000000000000000000100656f1e1e0000009d61a7c00000003e862817',
);

final _v26Frame = hex(
  'aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46f'
  'c8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe8'
  '4fe15ff5cff405fb33c50080101006cb67c17',
);

Uint8List innerOf(Uint8List frame) {
  final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
  expect(parsed.valid, isTrue, reason: 'both gen5 CRCs must check out');
  return Uint8List.fromList(parsed.inner);
}

void main() {
  group('inner[2] is a flags byte, and bit 7 is the PPG sample rate', () {
    test('both real fixtures declare 25 Hz', () {
      for (final frame in [_v18Frame, _v26Frame]) {
        final r = parseGen5Historical(innerOf(frame))!;
        expect(r.flags, 0x80);
        expect(r.flags & 0x80, isNonZero);
        expect(r.ppgSampleRateHz, 25);
      }
    });

    test('bit 7 clear means 50 Hz, and the other bits do not disturb it', () {
      final inner = innerOf(_v18Frame);
      for (final b in [0x00, 0x02, 0x7F, 0x80, 0x82, 0xFF]) {
        inner[2] = b;
        final r = parseGen5Historical(inner)!;
        expect(r.flags, b, reason: 'raw byte stays readable for bits 0/1');
        expect(r.ppgSampleRateHz, (b & 0x80) != 0 ? 25 : 50, reason: 'b=$b');
      }
    });

    test('the header exposes the same flags byte and rate', () {
      final hdr = Gen5HistoricalHeader.tryParse(innerOf(_v18Frame))!;
      expect(hdr.flags, 0x80);
      expect(hdr.ppgSampleRateHz, 25);
    });
  });

  group('the u16 sub-second at inner[11:13] is decoded, not dropped', () {
    test('v18 real fixture: 18022 → 0.5500 s', () {
      final s = parseGen5Historical(innerOf(_v18Frame)) as Gen5HistorySample;
      expect(s.tsSubsec, 18022);
      expect(s.subSecond, closeTo(0.5500, 1e-4));
    });

    test('v26 real fixture: 18350 → 0.5600 s', () {
      final w = parseGen5Historical(innerOf(_v26Frame)) as Gen5PpgWaveform;
      expect(w.tsSubsec, 18350);
      expect(w.subSecond, closeTo(0.5600, 1e-4));
      // Same bytes as the historical `segmentId`, and its 0..99 index is just
      // the sub-second in hundredths.
      expect(w.segmentId, w.tsSubsec);
      expect(w.segmentIndex, 56);
      // The deprecated byte read keeps only the low half.
      // ignore: deprecated_member_use_from_same_package
      expect(w.rawByte19, w.tsSubsec & 0xFF);
    });

    test('the Q15 scale holds for every verified raw value', () {
      final inner = innerOf(_v18Frame);
      const cases = {18350: 0.5600, 18022: 0.5500, 12124: 0.3700};
      cases.forEach((raw, seconds) {
        ByteData.sublistView(inner).setUint16(11, raw, Endian.little);
        final s = parseGen5Historical(inner) as Gen5HistorySample;
        expect(s.tsSubsec, raw);
        expect(s.subSecond, closeTo(seconds, 1e-4), reason: 'raw=$raw');
      });
    });

    test('the shared header reports it absent rather than zero when truncated',
        () {
      final short = innerOf(_v18Frame).sublist(0, 12);
      final hdr = Gen5HistoricalHeader.tryParse(short)!;
      expect(hdr.tsSubsec, isNull);
      expect(hdr.subSecond, isNull);
    });
  });

  group('v18 optical fields are two big-endian u16s', () {
    test('the real fixture pairs as 0x656F / 0x1E1E', () {
      final inner = innerOf(_v18Frame);
      final s = parseGen5Historical(inner) as Gen5HistorySample;
      expect(s.opticalBaseline, 0x656F);
      expect(s.opticalAmp, 0x1E1E);
      // Big-endian: the FIRST byte on the wire is the high half.

      expect(s.opticalAmp >> 8, inner[100]);
      expect(s.opticalAmp & 0xFF, inner[101]);
    });

    test('the sentinel is the single value 0x8080', () {
      final inner = innerOf(_v18Frame);
      inner[100] = 0x80;
      inner[101] = 0x80;
      final s = parseGen5Historical(inner) as Gen5HistorySample;
      expect(s.opticalAmp, 0x8080);
      expect(s.isOpticalAmpSentinel, isTrue);

      inner[101] = 0x7F; // one half alone is a real reading, not the sentinel
      final s2 = parseGen5Historical(inner) as Gen5HistorySample;
      expect(s2.opticalAmp, 0x807F);
      expect(s2.isOpticalAmpSentinel, isFalse);
    });
  });

  group('v18 signal quality + the fourth field in the sleep byte', () {
    test('the log-variance metric decodes off the real fixture', () {
      final s = parseGen5Historical(innerOf(_v18Frame)) as Gen5HistorySample;
      expect(s.signalQualityLogVariance, closeTo(-5.2307, 1e-4));
    });

    test('bits 6-7 of inner[73] are exposed alongside the other three fields',
        () {
      final inner = innerOf(_v18Frame);
      for (int b = 0; b <= 255; b++) {
        inner[73] = b;
        final s = parseGen5Historical(inner) as Gen5HistorySample;
        expect(s.onWristRaw, b & 0x03);
        expect(s.wakeQualityRaw, (b >> 2) & 0x03);
        expect(s.sleepStateRawNibble, (b >> 4) & 0x03);
        expect(s.bits67Raw, (b >> 6) & 0x03, reason: 'byte=$b');
      }
    });
  });

  group('exact record lengths', () {
    test('v18 is exactly 112 bytes and nothing else decodes as v18', () {
      final inner = innerOf(_v18Frame);
      expect(inner.length, 112);
      expect(parseGen5Historical(inner), isA<Gen5HistorySample>());

      for (final len in [109, 110, 111]) {
        expect(parseGen5Historical(inner.sublist(0, len)), isNull,
            reason: 'len=$len');
      }
      final long = Uint8List(113)..setRange(0, 112, inner);
      expect(parseGen5Historical(long), isNull, reason: 'len=113');
    });

    test('v26 is exactly 76 bytes and nothing else decodes as v26', () {
      final inner = innerOf(_v26Frame);
      expect(inner.length, 76);
      expect(parseGen5Historical(inner), isA<Gen5PpgWaveform>());

      for (final len in [67, 74, 75]) {
        expect(parseGen5Historical(inner.sublist(0, len)), isNull,
            reason: 'len=$len');
      }
      final long = Uint8List(77)..setRange(0, 76, inner);
      expect(parseGen5Historical(long), isNull, reason: 'len=77');
    });
  });

  group('v20 sample rate + block metadata', () {
    // Synthetic — no real v20 capture is available — but it exercises the
    // stated geometry (body @ 18, stride 422, slots at +21 / +221) and the
    // metadata field boundaries.
    Uint8List buildV20() {
      final inner = Uint8List(kGen5V20InnerLen);
      inner[0] = 0x2f;
      inner[1] = 20;
      inner[2] = 0x81; // 25 Hz + the IR-fallback flag (bit 0)
      final v = ByteData.sublistView(inner);
      v.setUint32(3, 11494060, Endian.little);
      v.setUint32(7, 1784054004, Endian.little);
      v.setUint16(11, 12124, Endian.little); // sub-second
      v.setUint16(15, 50, Endian.little); // sample rate, Hz
      for (int b = 0; b < 5; b++) {
        final start = 18 + b * 422;
        inner[start] = 25;
        // shared: [ledA conn][ledA current u16][ledB conn][ledB current u16]
        inner[start + 1] = 1;
        v.setUint16(start + 2, 2500, Endian.little); // 25.00 mA
        inner[start + 4] = 2;
        v.setUint16(start + 5, 40, Endian.little); // 400 µA
        // photodiode 0: [source][u32 adc range][u16 adc offset]
        inner[start + 7] = 3;
        v.setUint32(start + 8, 100000, Endian.little);
        v.setUint16(start + 12, 512, Endian.little);
        // photodiode 1
        inner[start + 14] = 4;
        v.setUint32(start + 15, 200000, Endian.little);
        v.setUint16(start + 19, 1024, Endian.little);
      }
      return inner;
    }

    test('the buffer carries its own sample rate and sub-second', () {
      final buf = parseGen5Historical(buildV20()) as Gen5OpticalBuffer;
      expect(buf.sampleRateHz, 50);
      expect(buf.tsSubsec, 12124);
      expect(buf.subSecond, closeTo(0.3700, 1e-4));
      expect(buf.flags, 0x81);
      expect(buf.ppgSampleRateHz, 25); // bit 7
      expect(buf.flags & 0x01, 1); // bit 0 — the block-3 fallback flag
    });

    test('block metadata decomposes into LED drive + per-photodiode ADC', () {
      final buf = parseGen5Historical(buildV20()) as Gen5OpticalBuffer;
      for (final blk in buf.blocks) {
        expect(blk.ledADriverConnection, 1);
        expect(blk.ledACurrentRaw, 2500);
        expect(blk.ledACurrentMicroamps, 25000); // units of 10 µA
        expect(blk.ledBDriverConnection, 2);
        expect(blk.ledBCurrentRaw, 40);
        expect(blk.ledBCurrentMicroamps, 400);
        expect(blk.channel0Source, 3);
        expect(blk.channel0AdcRange, 100000);
        expect(blk.channel0AdcOffset, 512);
        expect(blk.channel1Source, 4);
        expect(blk.channel1AdcRange, 200000);
        expect(blk.channel1AdcOffset, 1024);
        // The raw blobs stay available and still cover the same bytes.
        expect(blk.sharedMetaRaw, hasLength(6));
        expect(blk.channel0MetaRaw, hasLength(7));
        expect(blk.channel1MetaRaw, hasLength(7));
      }
    });
  });
}
