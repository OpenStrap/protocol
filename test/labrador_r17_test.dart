// Labrador R17 (WHOOP MG filtered ECG) parser — bounds, identity, signs,
// flags and preserved bytes. Fixtures are SYNTHETIC: the layout is the
// source-proven official parser map (docs/mg/02 §"Revision-17 packet body"),
// never a private capture.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// A physical-shaped inner: 228 bytes (the observed fixed inner size), with
/// every named field settable. [samples] beyond [count] are left zero, so a
/// count below capacity leaves an aligned tail exactly like the band does.
Uint8List r17Inner({
  int packetType = 0x2B,
  int secondary = 0,
  int sequence = 23940969,
  int strapSeconds = 1787823784,
  int subseconds = 12345,
  int quality = 1,
  int flags = 0x0a,
  int result = 0,
  int s2State = 1,
  int progress = 3,
  int unreadable = 0,
  int averageHr = 0,
  int liveHr = 70,
  int variability = 0xffff,
  int reserved = 0,
  int? declaredCount,
  List<int> samples = const [],
  int totalLen = 228,
  int revision = 17,
}) {
  final inner = Uint8List(totalLen);
  final v = ByteData.sublistView(inner);
  inner[0] = packetType;
  inner[1] = revision;
  inner[2] = secondary;
  v.setUint32(3, sequence, Endian.little);
  v.setUint32(7, strapSeconds, Endian.little);
  v.setUint16(11, subseconds, Endian.little);
  inner[13] = quality;
  inner[14] = flags;
  inner[15] = result;
  inner[16] = s2State;
  inner[17] = progress;
  inner[18] = unreadable;
  inner[19] = averageHr;
  inner[20] = liveHr;
  v.setUint16(21, variability, Endian.little);
  inner[23] = reserved;
  v.setUint16(24, declaredCount ?? samples.length, Endian.little);
  for (var i = 0; i < samples.length && 26 + 2 * i + 1 < totalLen; i++) {
    v.setInt16(26 + 2 * i, samples[i], Endian.little);
  }
  return inner;
}

void main() {
  group('identity', () {
    test('type 43 revision 17 parses; the fixed fields read at their offsets',
        () {
      final r = LabradorR17.parse(r17Inner(
        secondary: 0x80,
        quality: 3,
        flags: 0x0c,
        result: 1,
        s2State: 2,
        progress: 100,
        unreadable: 0,
        averageHr: 77,
        liveHr: 78,
        variability: 29,
        reserved: 0,
        samples: List.filled(100, 5),
      ))!;
      expect(r.packetType, 43);
      expect(r.isLive, isTrue);
      expect(r.headerSecondary, 0x80);
      expect(r.sequence, 23940969);
      expect(r.strapSeconds, 1787823784);
      expect(r.subseconds, 12345);
      expect(r.strapTime, closeTo(1787823784 + 12345 / 32768.0, 1e-9));
      expect(r.quality, 3);
      expect(r.flags.raw, 0x0c);
      expect(r.result, 1);
      expect(r.s2State, 2);
      expect(r.progress, 100);
      expect(r.isTerminal, isTrue);
      expect(r.isInvalid, isFalse);
      expect(r.averageHr, 77);
      expect(r.liveHr, 78);
      expect(r.variabilityRaw, 29);
      expect(r.reserved, 0);
      expect(r.sampleCount, 100);
      expect(r.samples, hasLength(100));
      expect(r.inner, hasLength(228));
    });

    test('type 47 is a STORED R17 — rejected unless the caller allows it', () {
      final inner = r17Inner(packetType: 0x2F, samples: [1, 2]);
      expect(LabradorR17.parse(inner), isNull);
      final r = LabradorR17.parse(inner, allowStored: true)!;
      expect(r.packetType, 47);
      expect(r.isLive, isFalse);
    });

    test('any other packet type is not an R17', () {
      for (final pt in [0x00, 0x23, 0x24, 0x28, 0x30, 0x31]) {
        expect(LabradorR17.parse(r17Inner(packetType: pt)), isNull,
            reason: 'packet type $pt');
        expect(LabradorR17.parse(r17Inner(packetType: pt), allowStored: true),
            isNull);
      }
    });

    test(
        'data revision must be 17 — 16, 18 and 21 in a type-43 envelope are '
        'other records', () {
      for (final rev in [16, 18, 21, 0, 255]) {
        expect(LabradorR17.parse(r17Inner(revision: rev)), isNull,
            reason: 'revision $rev');
      }
    });

    test('tryParseFrame requires a decodable frame', () {
      final inner = r17Inner(samples: [1]);
      final good = parseFrame(buildFrame(inner, profile: BandProfile.gen5),
          profile: BandProfile.gen5)!;
      expect(LabradorR17.tryParseFrame(good), isNotNull);
      // Corrupt one payload byte: CRC32 fails, the parser refuses.
      final raw = buildFrame(inner, profile: BandProfile.gen5);
      raw[8 + 30] ^= 0x01;
      final bad = parseFrame(raw, profile: BandProfile.gen5)!;
      expect(bad.crc32Ok, isFalse);
      expect(LabradorR17.tryParseFrame(bad), isNull);
      // A frame whose revision byte is not rev-1 is intact but unreadable.
      final rev2 = buildFrame(inner, profile: BandProfile.gen5);
      rev2[1] = 0x02;
      final f2 = parseFrame(rev2, profile: BandProfile.gen5)!;
      expect(f2.frameRevOk, isFalse);
      expect(LabradorR17.tryParseFrame(f2), isNull);
    });
  });

  group('sample block bounds', () {
    test('0, 49 and 100 samples (the physical startup counts) all parse', () {
      for (final n in [0, 49, 100]) {
        final r = LabradorR17.parse(
            r17Inner(samples: List.generate(n, (i) => i - 20)))!;
        expect(r.sampleCount, n, reason: 'count $n');
        expect(r.samples, List.generate(n, (i) => i - 20));
      }
    });

    test('a count above 100 is rejected even when the bytes would fit', () {
      final inner = r17Inner(declaredCount: 101, totalLen: 26 + 2 * 101 + 4);
      expect(LabradorR17.parse(inner), isNull);
    });

    test('a count whose sample block runs past the packet is rejected', () {
      // 100 declared, room for 99.
      final inner = r17Inner(declaredCount: 100, totalLen: 26 + 2 * 99);
      expect(LabradorR17.parse(inner), isNull);
      // Exactly enough bytes is fine.
      expect(
          LabradorR17.parse(r17Inner(declaredCount: 100, totalLen: 26 + 200)),
          isNotNull);
      // One byte short of the last sample is not.
      expect(
          LabradorR17.parse(r17Inner(declaredCount: 100, totalLen: 26 + 199)),
          isNull);
    });

    test('every truncation of the fixed fields is rejected', () {
      final full = r17Inner(samples: [1, 2, 3]);
      for (var len = 0; len < 26; len++) {
        expect(LabradorR17.parse(Uint8List.sublistView(full, 0, len)), isNull,
            reason: 'length $len');
      }
      // 26 bytes with count 0 is the smallest complete packet.
      final zero = r17Inner(samples: const [], totalLen: 26);
      expect(LabradorR17.parse(zero), isNotNull);
    });

    test('no fixed total length is required; the aligned tail is preserved',
        () {
      // 49 samples in a 228-byte inner leaves 228 - 124 = 104 tail bytes.
      final inner = r17Inner(samples: List.filled(49, 7));
      for (var i = 26 + 98; i < 228; i++) {
        inner[i] = (i * 31) & 0xff;
      }
      final r = LabradorR17.parse(inner)!;
      expect(r.tail, hasLength(104));
      expect(r.tail, inner.sublist(124));
      // And a packet with nothing after the samples has an empty tail.
      expect(LabradorR17.parse(r17Inner(samples: [1], totalLen: 28))!.tail,
          isEmpty);
    });
  });

  group('sample values', () {
    test('signed i16 little-endian, no rescale, no sign flip', () {
      final r = LabradorR17.parse(
          r17Inner(samples: [-1, 1, 0x7fff, -32768, -5396, 3377, 0]))!;
      expect(r.samples, [-1, 1, 32767, -32768, -5396, 3377, 0]);
      // Byte-level: -1 is ff ff, 1 is 01 00.
      expect(r.inner.sublist(26, 30), [0xff, 0xff, 0x01, 0x00]);
    });
  });

  group('flag byte 14', () {
    test('each bit independently', () {
      expect(LabradorR17.parse(r17Inner(flags: 0x01))!.flags.enteringS2One,
          isTrue);
      expect(LabradorR17.parse(r17Inner(flags: 0x01))!.flags.currentS2One,
          isFalse);
      expect(
          LabradorR17.parse(r17Inner(flags: 0x02))!.flags.currentS2One, isTrue);
      expect(LabradorR17.parse(r17Inner(flags: 0x04))!.flags.s2Transition1to2,
          isTrue);
      expect(LabradorR17.parse(r17Inner(flags: 0x08))!.flags.presence, isTrue);
      expect(LabradorR17.parse(r17Inner(flags: 0x08))!.presence, isTrue);
      expect(LabradorR17.parse(r17Inner(flags: 0x00))!.presence, isFalse);
      // Physical: 0x0a while contacted (presence + current S2 1), 0x0c on the
      // terminal transition, 0x08 afterwards.
      final contacted = LabradorR17.parse(r17Inner(flags: 0x0a))!.flags;
      expect(contacted.presence && contacted.currentS2One, isTrue);
      final term = LabradorR17.parse(r17Inner(flags: 0x0c))!.flags;
      expect(
          term.presence && term.s2Transition1to2 && !term.currentS2One, isTrue);
    });
  });

  group('unreadable mask byte 18', () {
    test('each bit independently, named in bit order', () {
      LabradorUnreadableMask m(int raw) =>
          LabradorR17.parse(r17Inner(unreadable: raw))!.unreadable;
      expect(m(0x01).lowAmplitude, isTrue);
      expect(m(0x01).reasons, ['low_amplitude']);
      expect(m(0x02).significantNoise, isTrue);
      expect(m(0x02).reasons, ['significant_noise']);
      expect(m(0x04).unstableSignal, isTrue);
      expect(m(0x04).reasons, ['unstable_signal']);
      expect(m(0x08).notEnoughData, isTrue);
      expect(m(0x08).reasons, ['not_enough_data']);
      expect(m(0x0f).reasons, [
        'low_amplitude',
        'significant_noise',
        'unstable_signal',
        'not_enough_data'
      ]);
      expect(m(0x00).reasons, isEmpty);
      expect(m(0x10).reasons, ['unknown_bits_0x10']);
    });
  });

  group('terminal / invalid / variability', () {
    test('terminal on progress 100 or S2 state 2; invalid on progress 255', () {
      expect(LabradorR17.parse(r17Inner(progress: 100))!.isTerminal, isTrue);
      expect(LabradorR17.parse(r17Inner(s2State: 2, progress: 96))!.isTerminal,
          isTrue);
      expect(LabradorR17.parse(r17Inner(progress: 99))!.isTerminal, isFalse);
      expect(LabradorR17.parse(r17Inner(progress: 255))!.isInvalid, isTrue);
      expect(LabradorR17.parse(r17Inner(progress: 255))!.isTerminal, isFalse);
    });

    test('variability 0xffff is unavailable (null); anything else is raw', () {
      expect(LabradorR17.parse(r17Inner(variability: 0xffff))!.variabilityRaw,
          isNull);
      expect(LabradorR17.parse(r17Inner(variability: 44))!.variabilityRaw, 44);
      expect(LabradorR17.parse(r17Inner(variability: 0))!.variabilityRaw, 0);
    });

    test('reserved byte 23 is exposed raw', () {
      expect(LabradorR17.parse(r17Inner(reserved: 9))!.reserved, 9);
    });
  });
}
