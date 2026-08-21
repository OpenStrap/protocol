// gen5 (WHOOP 5) revision-22 research/diagnostic record tests.
//
// The five hex bodies below are REAL 176-byte R22 inner packets, one per
// emitted tag, with their timestamp fields synthesized. Every cross-check
// value beside them (the twin R18's accel float bytes, its state word and
// its flags byte) comes from the R18 record with the SAME
// (record_index, unix) — the join key every R22 record carries.
//
// The synthetic cases fill every byte with a poison pattern first and then
// write only the offsets the layout assigns. That encodes the stale-bytes
// rule ("unwritten offsets retain the previous packet's content") as a test:
// if a decoder read one byte it should not, the poison would show up in a
// typed field.

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// tag 1 — a real capture record; the timestamp field is synthesized.
final Uint8List realTag1 = hex(
  '2f16806fc34b0101a5186ab81e0100ffcf030059027dffdffbe7fa58fa45fbbb'
  'fce0fd55feabfe83fe13ff48032c043d046c0525048f048f055f0610051a03fa'
  '0041fe0080000000000000000000000000000000000000000000000000000000'
  '0000000000000000000000000000000000000000000021f408e0ebe23d71dda9'
  '3d0a03433f663a263f5007010c020c0100000000000000000000000000000000'
  '00000000000000000000000000000000',
);

/// tag 2 — a real capture record from a band CONFIGURED for variant 3 that
/// emitted tag 2 (the 3→2 fallback, visible on the wire); the timestamp
/// field is synthesized.
final Uint8List realTag2 = hex(
  '2f16806ffa4c0102a5186a701d0200ffff070000000000000000000000000000'
  '0000000000000000000000000000000000000000000000000000000000000000'
  '0000000080000000000000000000000000000000000000000000000000000000'
  '00000000000000000000000000000000000000000005000000b81c623eae57b8'
  'bea4443f3f52fc103ff057010c020c0000000000000000000000000000000000'
  '00000000000000000000000000000000',
);

/// tag 3 — a real capture record (natural sleep); the timestamp field is
/// synthesized.
final Uint8List realTag3 = hex(
  '2f1680c368500103a5186aa3100300ced10100460044004d0044004d00440040'
  '00dbfe66fd6a00bd009600008000000000000000000000000000000000000000'
  '00ad00ffff070000000000000000000000000000000000000000000000000000'
  '80000000000000000000000000000000000000000080e080e02e41809ad63bf6'
  '6880bd5c3fa0bea48c70bf50020107f257000000000000000000000000000000'
  '00000000000000000000000000000000',
);

/// tag 5 — a real capture record; both timestamp fields are synthesized,
/// preserving the wire fact that the embedded PIP ring record is stamped
/// 39 s earlier than the carrier.
final Uint8List realTag5 = hex(
  '2f16805c054d013fa5186a7a54050018a5186ac2550100615b00004201bd02a9'
  'fe8803a10040ffbefdd5faccfcf0fb7bfc04fee9fe33ffb6fda0fe6bfd03fe62'
  'ffdcff5dff71fef3fd99fc50a9063f6003000000000000000000000000000000'
  '0000000000000000000000000000000000000000000060c509a89a033e852f75'
  'bf3dfadf3e7ba4203e6003dd00020c00000000000000000000000000000000dd'
  '00000000000000000000000000000000',
);

/// tag 6 — a real capture record; the timestamp field is synthesized.
final Uint8List realTag6 = hex(
  '2f1680a1e24c0106a5186a701d0600000000f301e301290243021302db014802'
  '81010b02d900c1016d0290023902230235025d024202470261026f0271024102'
  '47026d02b108050744070508a507a6077908b50600079809a507e707ed075508'
  'af07a60728086c081d08d507b8075d072a07a007ca073e0d240e2b0ed90dfa0d'
  '1a0e950eb20e4d0b510f260ec20de70dda0d150e040e700d7b0dab0dcf0ec70d'
  'ea0df70d020ee60d0000000064000000',
);

/// A 176-byte R22 inner whose every body byte is poison, so any accessor that
/// reads an offset its tag does not assign shows it.
Uint8List poisonBody(int tag) {
  final inner = Uint8List(kGen5V22InnerLen);
  for (int i = 0; i < inner.length; i++) {
    inner[i] = 0xA5;
  }
  inner[0] = 0x2F;
  inner[1] = 22;
  inner[2] = 0x80; // bit 7 set: 25 Hz optical front end
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 4242, Endian.little);
  v.setUint32(7, 1780000000, Endian.little);
  v.setUint16(11, 1234, Endian.little);
  inner[13] = tag;
  inner[14] = 0x00;
  return inner;
}

/// Write the tags-1/2/3/4 metadata block at [base].
void writeMetaBlock(
  Uint8List inner, {
  required int base,
  required int flagsSnapshot,
  required double accelDeltaG,
  required double f1,
  required double f2,
  required double f3,
  required int stateWord,
  required int primaryFlags,
}) {
  final v = ByteData.sublistView(inner);
  inner[base + 1] = flagsSnapshot;
  v.setFloat32(base + 4, accelDeltaG, Endian.little);
  v.setFloat32(base + 8, f1, Endian.little);
  v.setFloat32(base + 12, f2, Endian.little);
  v.setFloat32(base + 16, f3, Endian.little);
  v.setUint16(base + 20, stateWord, Endian.little);
  inner[base + 26] = primaryFlags;
}

void writeWindow(
  Uint8List inner, {
  required int start,
  required int firstSample,
  required List<int> deltas,
}) {
  final v = ByteData.sublistView(inner);
  v.setInt32(start, firstSample, Endian.little);
  for (int i = 0; i < deltas.length; i++) {
    v.setInt16(start + 4 + 2 * i, deltas[i], Endian.little);
  }
}

void main() {
  group('Gen5V22Decoder — registration and gating', () {
    test('is registered in kGen5HistoricalDecoders', () {
      expect(
        kGen5HistoricalDecoders.map((d) => d.name),
        contains('gen5_v22'),
      );
    });

    test('parseGen5Historical dispatches revision 22', () {
      expect(parseGen5Historical(realTag1), isA<Gen5ResearchRecord>());
    });

    test('the length gate is EXACT (176), not a floor', () {
      const dec = Gen5V22Decoder();
      expect(dec.matches(realTag1), isTrue);
      for (final len in [kGen5V22InnerLen - 1, kGen5V22InnerLen + 1]) {
        final wrong = Uint8List(len);
        wrong[0] = 0x2F;
        wrong[1] = 22;
        expect(dec.matches(wrong), isFalse, reason: 'len=$len');
        expect(dec.decode(wrong), isNull, reason: 'len=$len');
        expect(parseGen5Historical(wrong), isNull, reason: 'len=$len');
      }
    });

    test('a 176-byte record of another revision is not claimed', () {
      final other = Uint8List.fromList(realTag1);
      other[1] = 20;
      expect(const Gen5V22Decoder().matches(other), isFalse);
    });

    test('an unknown tag still decodes to header + tag + rawBody', () {
      final inner = poisonBody(7);
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.tag, 7);
      expect(r.hasKnownLayout, isFalse);
      expect(r.rawBody, hasLength(kGen5V22InnerLen - 13)); // 163-byte body
      expect(r.rawBody[0], 7); // body 0 is the tag itself
      expect(r.opticalWindows, isEmpty);
      expect(r.accelDeltaG, isNull);
      expect(r.channelStateWord, isNull);
      expect(r.primaryFlagsByte, isNull);
      expect(r.primaryFlagsBit8Raw, isNull);
      expect(r.flagsSnapshotByte, isNull);
      expect(r.unnamedMetadataFloats, isEmpty);
      expect(r.pipRecordUnix, isNull);
      expect(r.accelRawX, isEmpty);
      expect(r.accelTailRaw, isEmpty);
      expect(r.extendedMetricsRaw, isEmpty);
    });

    test('the shared header decodes like every other gen5 record kind', () {
      final r = parseGen5Historical(realTag1) as Gen5ResearchRecord;
      expect(r.histVersion, 22);
      expect(r.flags, 0x80);
      expect(r.ppgSampleRateHz, 25); // flags bit 7 — every checked record is 25 Hz
      expect(r.recordIndex, 21742447);
      expect(r.unix, 1780000001);
      expect(r.tsSubsec, 0x1EB8);
    });
  });

  group('tag 1 — real capture', () {
    late Gen5ResearchRecord r;
    setUp(() => r = parseGen5Historical(realTag1) as Gen5ResearchRecord);

    test('one 49-slot optical window at inner[15]', () {
      expect(r.tag, 1);
      expect(r.opticalWindows, hasLength(1));
      final w = r.opticalWindows.single;
      expect(w.innerOffset, 15);
      expect(w.firstSampleAdc, 0x0003CFFF); // 249855
      expect(w.firstSampleAdcInRange, isTrue);
      expect(w.deltas, hasLength(49));
      expect(w.deltas[0], 601);
      expect(w.deltas[24], -32768); // the padding marker
      expect(w.deltas.sublist(25).every((d) => d == 0), isTrue);
    });

    test('the reconstruction reports where it stops being trustworthy', () {
      final rec = r.opticalWindows.single.reconstructWindow();
      expect(rec.samples, hasLength(50));
      expect(rec.samples.first, 249855);
      // A -32768 delta at index 24 poisons sample 25 and everything after it:
      // 25 usable samples, which is the 25 Hz mode. Nothing in the body says
      // so — the marker is the only signal, and it is ambiguous by design.
      expect(rec.firstAmbiguousSampleIndex, 25);
      expect(rec.trustedSampleCount, 25);
      expect(rec.hasSaturatedDelta, isTrue);
      expect(rec.outOfRangeSampleIndices, isEmpty);
    });

    test('the metadata block mirrors the paired R18 record', () {
      // The twin R18: inner[33:37] = e0ebe23d,
      // inner[67:69] = 1872, inner[73] = 1.
      expect(r.accelDeltaG, closeTo(0.11080145835876465, 1e-12));
      expect(r.channelStateWord, 1872);
      expect(r.primaryFlagsByte, 1);
      expect(r.primaryFlagsBit8Raw, 1);
      expect(r.flagsSnapshotByte, 0x21);
      expect(r.flagsSnapshotByte! & 3, 1); // only these two bits are proven
      expect(r.unnamedMetadataFloats, hasLength(3));
      expect(r.unnamedMetadataFloats[0], closeTo(0.082938, 1e-5));
    });

    test('tag 1 writes nothing in the tag-2/4 extension region', () {
      expect(r.extendedMetricsRaw, isEmpty);
      expect(r.accelRawX, isEmpty);
      expect(r.pipRecordUnix, isNull);
      expect(r.rawBody, hasLength(163));
    });
  });

  group('tag 2 — real capture (a variant-3 writer that fell back)', () {
    late Gen5ResearchRecord r;
    setUp(() => r = parseGen5Historical(realTag2) as Gen5ResearchRecord);

    test('a clipped-flat window is detectable, not silently "valid"', () {
      expect(r.tag, 2);
      final w = r.opticalWindows.single;
      expect(w.firstSampleAdc, 524287); // the +2^19-1 clip code
      expect(w.isClippedFlat, isTrue);
      // It reconstructs to a perfectly flat, perfectly plausible line — which
      // is exactly why clipping has to be detected separately.
      final rec = w.reconstructWindow();
      expect(rec.outOfRangeSampleIndices, isEmpty);
      expect(rec.samples.take(25).every((s) => s == 524287), isTrue);
    });

    test('isClippedFlat treats +32767 as an in-band terminator like -32768',
        () {
      // Both i16 rails end the usable band; a clipped-flat window whose
      // in-band zeros run into the POSITIVE rail is exactly as empty as one
      // ending on the negative rail.
      const positive = Gen5ResearchOpticalWindow(
        innerOffset: 15,
        firstSampleAdc: 524287,
        deltas: [0, 0, 0, 32767, 12, -9],
      );
      expect(positive.isClippedFlat, isTrue);
      const negative = Gen5ResearchOpticalWindow(
        innerOffset: 15,
        firstSampleAdc: 524287,
        deltas: [0, 0, 0, -32768, 12, -9],
      );
      expect(negative.isClippedFlat, isTrue);
      const realSignal = Gen5ResearchOpticalWindow(
        innerOffset: 15,
        firstSampleAdc: 524287,
        deltas: [0, 5, 0, -32768],
      );
      expect(realSignal.isClippedFlat, isFalse,
          reason: 'a nonzero in-band delta is signal, not clip');
    });

    test('the metadata block mirrors the paired R18 record', () {
      expect(r.accelDeltaG, closeTo(0.22081267833709717, 1e-12));
      expect(r.channelStateWord, 22512);
      expect(r.primaryFlagsByte, 0);
      expect(r.flagsSnapshotByte, 0x00);
    });

    test('the located-but-unsplit extension region is exposed raw', () {
      expect(r.extendedMetricsRaw, hasLength(11)); // inner[144:155]
    });
  });

  group('tag 3 — real capture (two optical windows, metadata shifted +2)', () {
    late Gen5ResearchRecord r;
    setUp(() => r = parseGen5Historical(realTag3) as Gen5ResearchRecord);

    test('two 24-slot windows at inner[15] and inner[67]', () {
      expect(r.tag, 3);
      expect(r.opticalWindows, hasLength(2));
      final a = r.opticalWindows[0];
      final b = r.opticalWindows[1];
      expect(a.innerOffset, 15);
      expect(a.firstSampleAdc, 0x0001D1CE); // 119246
      expect(a.deltas, hasLength(24));
      expect(a.deltas[0], 70);
      expect(a.deltas[12], -32768);
      expect(a.reconstructWindow().trustedSampleCount, 13);
      expect(b.innerOffset, 67);
      expect(b.firstSampleAdc, 524287);
      expect(b.isClippedFlat, isTrue);
      expect(b.deltas[12], -32768);
    });

    test('the metadata block sits at inner[119], +2 from tags 1/2/4', () {
      // The twin R18: inner[33:37] = 809ad63b,
      // inner[67:69] = 592, inner[73] = 32 (&3 == 0).
      expect(r.accelDeltaG, closeTo(0.006549179553985596, 1e-12));
      expect(r.channelStateWord, 592);
      expect(r.primaryFlagsByte, 0);
      expect(r.flagsSnapshotByte, 0xE0);
      expect(r.flagsSnapshotByte! & 3, 0);
      expect(r.extendedMetricsRaw, isEmpty);
    });
  });

  group('tag 5 — real capture (embedded PIP ring record)', () {
    late Gen5ResearchRecord r;
    setUp(() => r = parseGen5Historical(realTag5) as Gen5ResearchRecord);

    test('the ring record carries its OWN timestamp, 39 s behind the carrier',
        () {
      expect(r.tag, 5);
      expect(r.unix, 1780000063);
      expect(r.pipRecordUnix, 1780000024);
      expect(r.unix - r.pipRecordUnix!, 39);
    });

    test('one 24-slot window at inner[23], no saturation in this record', () {
      final w = r.opticalWindows.single;
      expect(w.innerOffset, 23);
      expect(w.firstSampleAdc, 0x00005B61); // 23393
      expect(w.deltas, hasLength(24));
      expect(w.deltas.contains(-32768), isFalse);
      expect(w.reconstructWindow().hasSaturatedDelta, isFalse);
      expect(w.reconstructWindow().samples, hasLength(25));
    });

    test('its mirrors match the R18 of the RING second, not the carrier', () {
      // The R18 of the embedded record's second: inner[33:37] = 50a9063f,
      // inner[67:69] = 864, inner[73] & 3 = 0. The carrier's own R18 reads
      // 0.10741591453552246 / 864 / 1 — a different accel value, which is what
      // makes this a real check rather than a tautology.
      expect(r.accelDeltaG, closeTo(0.5260210037231445, 1e-12));
      expect(r.channelStateWord, 864);
      expect(r.primaryFlagsByte, 0);
    });

    test('the stale tail is NOT decoded as tag-1/2/4 metadata', () {
      // inner[83:176] of this body is byte-identical to the PREVIOUS R22
      // packet (the stale-bytes rule, visible on the wire). The
      // bytes at inner[121:125] therefore hold the previous packet's accel
      // float, 0.1284..., and a decoder that read the shared metadata block
      // here would report that as this record's.
      final stale = ByteData.sublistView(realTag5).getFloat32(121, Endian.little);
      expect(stale, isNot(closeTo(r.accelDeltaG!, 1e-6)));
      expect(r.flagsSnapshotByte, isNull); // tag 5 has no such byte
      expect(r.unnamedMetadataFloats, isEmpty);
      expect(r.extendedMetricsRaw, isEmpty);
      // The bytes are still all there for a later analysis.
      expect(r.rawBody, hasLength(163));
      expect(r.rawBody[121 - 13], realTag5[121]);
    });
  });

  group('tag 6 — real capture (25 x i16 acceleration per axis)', () {
    late Gen5ResearchRecord r;
    setUp(() => r = parseGen5Historical(realTag6) as Gen5ResearchRecord);

    test('three 25-sample axes at inner[18] / [68] / [118]', () {
      expect(r.tag, 6);
      expect(r.accelRawX, hasLength(25));
      expect(r.accelRawY, hasLength(25));
      expect(r.accelRawZ, hasLength(25));
      expect(r.accelRawX.first, 499);
      expect(r.accelRawX.last, 621);
      expect(r.accelRawY.first, 2225);
      expect(r.accelRawZ.first, 3390);
      expect(r.accelRawZ.last, 3558);
    });

    test('the 4096 LSB/g scale puts a resting wrist at 1 g', () {
      expect(r.accelXg.first, closeTo(499 / 4096.0, 1e-12));
      var total = 0.0;
      for (int i = 0; i < 25; i++) {
        final x = r.accelXg[i];
        final y = r.accelYg[i];
        final z = r.accelZg[i];
        final mag = math.sqrt(x * x + y * y + z * z);
        expect(mag, closeTo(1.0, 0.25), reason: 'sample $i');
        total += mag;
      }
      // Over the whole 20-record capture the mean is 1.0406 g; this record's
      // own mean is the same order. Anything else would mean the axes are not
      // where this decoder puts them, or the scale is not 4096 LSB/g.
      expect(total / 25, closeTo(1.0, 0.1));
    });

    test('tag 6 carries no optical window and no R18 mirror', () {
      expect(r.opticalWindows, isEmpty);
      expect(r.accelDeltaG, isNull);
      expect(r.channelStateWord, isNull);
      expect(r.primaryFlagsByte, isNull);
      expect(r.flagsSnapshotByte, isNull);
      expect(r.unnamedMetadataFloats, isEmpty);
    });

    test('the eight tail bytes are raw — the doc\'s counters are unconfirmed',
        () {
      expect(r.accelTailRaw, hasLength(8)); // inner[168:176]
      expect(r.accelTailRaw, [0, 0, 0, 0, 0x64, 0, 0, 0]);
    });
  });

  group('synthetic bodies — only the assigned offsets are read', () {
    test('tag 1 over a poisoned body', () {
      final inner = poisonBody(1);
      writeWindow(
        inner,
        start: 15,
        firstSample: -12345,
        deltas: List<int>.generate(49, (i) => i < 24 ? i - 12 : 0)
          ..[24] = -32768,
      );
      writeMetaBlock(
        inner,
        base: 117,
        flagsSnapshot: 0x61,
        accelDeltaG: 0.25,
        f1: -0.5,
        f2: 0.75,
        f3: 1.5,
        stateWord: 0xBEEF,
        primaryFlags: 1,
      );
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.opticalWindows.single.firstSampleAdc, -12345);
      expect(r.opticalWindows.single.deltas[24], -32768);
      expect(r.accelDeltaG, 0.25);
      expect(r.unnamedMetadataFloats, [-0.5, 0.75, 1.5]);
      expect(r.channelStateWord, 0xBEEF);
      expect(r.primaryFlagsByte, 1);
      expect(r.flagsSnapshotByte, 0x61);
      // Nothing leaked from the poisoned, unassigned bytes.
      expect(r.extendedMetricsRaw, isEmpty);
      expect(r.accelRawX, isEmpty);
      expect(r.pipRecordUnix, isNull);
      // …but the poison is preserved verbatim in the raw body.
      expect(r.rawBody[160 - 13], 0xA5);
    });

    test('tag 2 exposes the extension region without naming anything in it',
        () {
      final inner = poisonBody(2);
      writeWindow(inner, start: 15, firstSample: 100, deltas: List.filled(49, 0));
      writeMetaBlock(
        inner,
        base: 117,
        flagsSnapshot: 0,
        accelDeltaG: 1.0,
        f1: 0,
        f2: 0,
        f3: 0,
        stateWord: 1,
        primaryFlags: 0,
      );
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.extendedMetricsRaw, hasLength(11));
      expect(r.extendedMetricsRaw.every((b) => b == 0xA5), isTrue);
    });

    test('tag 4 shares the tag-1/2 layout and writes the extension region',
        () {
      // Tag 4 rides the shared tag-1/2/4 branch behind an `tag != 1` gate for
      // the extension region; a regression narrowing that gate to tag 2 would
      // pass every other test here.
      final inner = poisonBody(4);
      writeWindow(
          inner, start: 15, firstSample: 300, deltas: List.filled(49, 0));
      writeMetaBlock(
        inner,
        base: 117,
        flagsSnapshot: 0x10,
        accelDeltaG: 0.5,
        f1: 0,
        f2: 0,
        f3: 0,
        stateWord: 1872,
        primaryFlags: 1,
      );
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.opticalWindows.single.deltas, hasLength(49));
      expect(r.accelDeltaG, 0.5);
      expect(r.channelStateWord, 1872);
      expect(r.flagsSnapshotByte, 0x10);
      expect(r.extendedMetricsRaw, hasLength(11));
      expect(r.pipRecordUnix, isNull);
      expect(r.accelRawX, isEmpty);
    });

    test('tag 3 reads two windows and the +2 metadata base', () {
      final inner = poisonBody(3);
      writeWindow(
        inner,
        start: 15,
        firstSample: 1000,
        deltas: List<int>.generate(24, (i) => i + 1),
      );
      writeWindow(
        inner,
        start: 67,
        firstSample: -2000,
        deltas: List<int>.generate(24, (i) => -(i + 1)),
      );
      writeMetaBlock(
        inner,
        base: 119,
        flagsSnapshot: 0x20,
        accelDeltaG: 0.125,
        f1: 1,
        f2: 2,
        f3: 3,
        stateWord: 592,
        primaryFlags: 0,
      );
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.opticalWindows.map((w) => w.firstSampleAdc), [1000, -2000]);
      expect(r.opticalWindows[0].deltas.first, 1);
      expect(r.opticalWindows[1].deltas.first, -1);
      expect(r.accelDeltaG, 0.125);
      expect(r.channelStateWord, 592);
      expect(r.flagsSnapshotByte, 0x20);
      expect(r.primaryFlagsByte, 0);
    });

    test('tag 5 reads the ring record, never the shared metadata block', () {
      final inner = poisonBody(5);
      final v = ByteData.sublistView(inner);
      v.setUint32(15, 1780000024, Endian.little);
      writeWindow(
        inner,
        start: 23,
        firstSample: 4096,
        deltas: List<int>.filled(24, 7),
      );
      v.setFloat32(75, 0.5, Endian.little);
      v.setUint16(79, 864, Endian.little);
      inner[81] = 1;
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.pipRecordUnix, 1780000024);
      expect(r.opticalWindows.single.firstSampleAdc, 4096);
      expect(r.opticalWindows.single.deltas, hasLength(24));
      expect(r.accelDeltaG, 0.5);
      expect(r.channelStateWord, 864);
      expect(r.primaryFlagsByte, 1);
      expect(r.primaryFlagsBit8Raw, 1);
      // inner[117:176] is 0xA5 poison here; nothing read it.
      expect(r.flagsSnapshotByte, isNull);
      expect(r.unnamedMetadataFloats, isEmpty);
    });

    test('tag 6 reads three axes and the raw tail', () {
      final inner = poisonBody(6);
      final v = ByteData.sublistView(inner);
      for (int i = 0; i < 25; i++) {
        v.setInt16(18 + 2 * i, 4096, Endian.little); // 1.0 g
        v.setInt16(68 + 2 * i, -2048, Endian.little); // -0.5 g
        v.setInt16(118 + 2 * i, 0, Endian.little);
      }
      for (int o = 168; o < kGen5V22InnerLen; o++) {
        inner[o] = o - 168;
      }
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.accelXg.every((g) => g == 1.0), isTrue);
      expect(r.accelYg.every((g) => g == -0.5), isTrue);
      expect(r.accelZg.every((g) => g == 0.0), isTrue);
      expect(r.accelTailRaw, [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(r.opticalWindows, isEmpty);
    });
  });

  group('reconstruction guards carry over from v26', () {
    test('an out-of-range reconstructed sample is reported', () {
      final inner = poisonBody(1);
      writeWindow(
        inner,
        start: 15,
        firstSample: 524000,
        deltas: List<int>.filled(49, 1000),
      );
      writeMetaBlock(
        inner,
        base: 117,
        flagsSnapshot: 0,
        accelDeltaG: 0,
        f1: 0,
        f2: 0,
        f3: 0,
        stateWord: 0,
        primaryFlags: 0,
      );
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      final rec = r.opticalWindows.single.reconstructWindow();
      expect(rec.divergenceProven, isTrue);
      expect(rec.outOfRangeSampleIndices.first, 1); // 524000 + 1000 > 524287
    });

    test('a non-finite metadata float abstains rather than fabricating', () {
      final inner = poisonBody(1);
      writeWindow(inner, start: 15, firstSample: 0, deltas: List.filled(49, 0));
      final v = ByteData.sublistView(inner);
      v.setUint32(117 + 4, 0x7FC00000, Endian.little); // NaN
      v.setUint32(117 + 8, 0x7F800000, Endian.little); // +Inf
      v.setFloat32(117 + 12, 1.0, Endian.little);
      v.setFloat32(117 + 16, 2.0, Endian.little);
      v.setUint16(117 + 20, 0, Endian.little);
      inner[117 + 26] = 0;
      final r = parseGen5Historical(inner) as Gen5ResearchRecord;
      expect(r.accelDeltaG, isNull);
      expect(r.unnamedMetadataFloats, [null, 1.0, 2.0]);
    });
  });
}
