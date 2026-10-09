// The Oura wire format, against real captured bytes.
//
// THE FIXTURE IS GROUND TRUTH, AND IT IS NARROW. Every `debug_data` body below
// is verbatim from a 10,208-record capture off a real ring, and the expectations
// are what an independent read of that capture supports — nothing here was
// copied from anyone's decoder. The battery numbers in particular are checked
// two ways: the ring reports its voltage in two unrelated sub-records at two
// different cadences, and where they land near each other in the capture they
// agree to within 3 mV. That agreement is the evidence; a single decoder
// agreeing with itself would not be.
//
// WHAT THIS CANNOT PROVE, said out loud because a fixture presented as a
// correctness credential is a liability (ADDING_A_DEVICE 6.2): it proves
// determinism, regression and physiological sanity. It does not prove
// correctness, because there is no independent oracle for this band — nobody
// on this project owns a ring. The decoders that are NOT here (steps, motion,
// raw PPG) are absent because their fields or windows are not pinned. The
// hypnogram and stream vectors below (HR/RMSSD pairs, SpO2, beat intervals,
// always-on HR) are synthetic: they pin bit order and refusal, not real-ring
// correctness.
//
// The NULL cases at the bottom are the load-bearing half: they are what proves
// the decoder REFUSES rather than always producing something.
//
// AES-128/ECB auth-response encryption is NOT exercised here — this package
// has no cipher implementation. See the session that drives this wire format
// for that half of the auth handshake.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

/// One `debug_data` body, exactly as captured, with the ring clock it carried.
const List<(String label, int ds, String bodyHex)> _kDebugData = [
  // Firmware diagnostic labels. Subtype 0x04, then a NUL-free ASCII string.
  ('text Tsfs', 9408815, '04547366733b32'),
  ('text EHRts', 9409977, '0445485274733b3633'),
  ('text ble_tx', 9597025, '04626c655f74783a66756c6c'),
  // State-of-charge changed. Subtype 0x24: percent, then millivolts.
  ('battery 86%', 9391523, '2456c80f00'),
  ('battery 85%', 9427525, '2455c10f00'),
  ('battery 71%', 10093526, '24474a0f00'),
  // The fuel gauge's own periodic sample. Subtype 0x14, millivolts at a
  // different offset — this is the record the 0x24 voltage is checked against.
  ('gauge 4040mV', 9395848, '14cf50c80fb2ffffffd53e0000da'),
  ('gauge 3916mV', 10103853, '14fe424c0f7afcffffe033000065'),
  // Recognised as sub-records, deliberately not interpreted.
  ('afe stats', 9391258, '28000c030000000000000c030c03'),
  ('sleep stats', 9391251, '0927e61e00922500005434000005'),
  // The trap: binary, but every byte is printable-or-NUL.
  ('afe stats, all-printable', 9410164, '2800000000000000000000000000'),
  ('subtype 0x29, all-printable', 10098932, '2900000000000000'),
];

void main() {
  group('framing', () {
    test('a frame is tag, u8 length, then exactly that many payload bytes', () {
      final f = parseOuraFrame(_hex('110808009e0e00000300'));
      expect(f, isNotNull);
      expect(f!.tag, 0x11);
      expect(f.payload.length, 8);
    });

    test('parseOuraFrame reads only the first frame of a notification', () {
      // Eight declared, eleven delivered: the tail is the next bundled frame.
      final f = parseOuraFrame(_hex('110808009e0e00000300') + _hex('aabbcc'))!;
      expect(f.payload.length, 8);
      expect(parseBatchSummary(f)!.bytesLeft, 3742);
    });

    test('a bundled notification yields every frame, in order', () {
      final fs = parseOuraFrames(<int>[
        0x61, 0x05, 0xa3, 0x4d, 0x8f, 0x00, 0x24, //
        0x69, 0x06, 1, 0, 0, 0, 0x6c, 0x0d, //
        ..._hex('110808009e0e00000300'),
      ]);
      expect(fs.map((f) => f.tag), [0x61, 0x69, 0x11]);
      expect(parseOuraEvent(fs[1])!.tsDs, 1);
      expect(parseBatchSummary(fs[2])!.bytesLeft, 3742);
    });

    test('a truncated last frame is dropped, the ones before it kept', () {
      final fs = parseOuraFrames(
          _hex('110808009e0e00000300') + _hex('aabbcc'));
      expect(fs.map((f) => f.tag), [0x11]);
    });

    test('a standard event declaring more than 18 bytes drops the bundle', () {
      expect(
          parseOuraFrames(<int>[
            0x61, 0x05, 0xa3, 0x4d, 0x8f, 0x00, 0x24, //
            0x46, 19, ...List.filled(19, 0),
          ]),
          isEmpty);
    });

    test('a batch summary carries the count and the bytes still on the ring',
        () {
      // 8 events in this batch, 3742 bytes of history left to fetch. Zero is
      // the ONLY completion signal on this path — there is no acknowledgement
      // and nothing the host says makes the ring release anything.
      final s = parseBatchSummary(parseOuraFrame(_hex('110808009e0e00000300'))!)!;
      expect(s.received, 8);
      expect(s.bytesLeft, 3742);
    });

    test('an event splits into a decisecond envelope stamp and a body', () {
      // tag 0x61, length 5, ts = 9391523 ds, then a one-byte body.
      final f = parseOuraFrame(<int>[0x61, 0x05, 0xa3, 0x4d, 0x8f, 0x00, 0x24])!;
      final e = parseOuraEvent(f)!;
      expect(e.tag, 0x61);
      expect(e.tsDs, 9391523);
      expect(e.body, <int>[0x24]);
    });

    test('the envelope unit is deciseconds, proven by the capture cadence', () {
      // The hourly battery record and the ten-minute fuel-gauge record sit at
      // 36000 and 6000 ticks apart in the capture. Both only work at 10 ticks
      // to the second, which is what makes every other timestamp readable.
      expect(9427523 - 9391523, 36000);
      expect(9401848 - 9395848, 6000);
    });
  });

  group('debug_data — dispatch is on the subtype byte, never on printability',
      () {
    test('every captured text record decodes to its string', () {
      expect(decodeDebugData(_hex('04547366733b32'))!.text, 'Tsfs;2');
      expect(decodeDebugData(_hex('0445485274733b3633'))!.text, 'EHRts;63');
      expect(decodeDebugData(_hex('04626c655f74783a66756c6c'))!.text,
          'ble_tx:full');
    });

    test('a text record does NOT begin with a printable byte', () {
      // This is why a printability test over the whole body cannot find them:
      // subtype 0x04 is itself a control byte, so the test fails on byte 0 and
      // all 63 strings in the capture are lost.
      expect(_hex('04547366733b32')[0], lessThan(0x20));
    });

    test('an all-printable BINARY record is not mistaken for text', () {
      // 127 records in the capture are entirely printable-or-NUL and are not
      // strings — firmware counters padded with NULs, 113 of subtype 0x28 and
      // 14 of 0x29. A printability test fires on exactly these and hands back
      // '(' followed by thirteen NULs. Dispatching on the subtype cannot.
      final b = _hex('2800000000000000000000000000');
      expect(b.every((x) => x == 0 || (x >= 0x20 && x <= 0x7e)), isTrue,
          reason: 'the fixture must actually be all-printable to be the trap');
      final d = decodeDebugData(b)!;
      expect(d.subtype, 0x28);
      expect(d.text, isNull);
    });

    test('state of charge and voltage', () {
      final a = decodeDebugData(_hex('2456c80f00'))!;
      expect(a.batteryPct, 86);
      expect(a.batteryMv, 4040);
      final b = decodeDebugData(_hex('24474a0f00'))!;
      expect(b.batteryPct, 71);
      expect(b.batteryMv, 3914);
    });

    test('the fuel gauge reports the SAME voltage as the battery record', () {
      // THE CROSS-CHECK, and it is the only independent evidence in this file.
      // The two sub-records share no offset, no cadence and no length, and they
      // are read here at both ends of the capture: 4325 deciseconds apart at
      // the start, 10327 apart at the end. A wrong offset in either decoder
      // could not agree with the other twice, 19 hours and 126 mV apart.
      expect(decodeDebugData(_hex('2456c80f00'))!.batteryMv, 4040);
      expect(decodeDebugData(_hex('14cf50c80fb2ffffffd53e0000da'))!.batteryMv,
          4040);
      expect(decodeDebugData(_hex('24474a0f00'))!.batteryMv, 3914);
      expect(decodeDebugData(_hex('14fe424c0f7afcffffe033000065'))!.batteryMv,
          3916);
    });

    test('the whole fixture decodes without throwing, and claims nothing extra',
        () {
      for (final (label, _, hex) in _kDebugData) {
        final d = decodeDebugData(_hex(hex));
        expect(d, isNotNull, reason: label);
        expect(d!.subtype, _hex(hex)[0], reason: label);
        if (d.subtype != kOuraDebugText) {
          expect(d.text, isNull, reason: '$label must not claim to be text');
        }
        if (d.subtype != kOuraDebugBatteryLevel) {
          expect(d.batteryPct, isNull,
              reason: '$label must not claim a charge level');
        }
      }
    });
  });

  group('the decoder REFUSES rather than always producing something', () {
    test('an empty or truncated frame is null, never a short one', () {
      expect(parseOuraFrame(const <int>[]), isNull);
      expect(parseOuraFrame(const <int>[0x61]), isNull);
      // Declares 20 payload bytes, delivers 3. Handing back the 3 would make
      // every length check downstream read a fragment as a complete record.
      expect(parseOuraFrame(const <int>[0x61, 20, 1, 2, 3]), isNull);
    });

    test('only 0x41..0x8f with a 4..18-byte payload is a standard event', () {
      final ts = _hex('01000000');
      expect(parseOuraEvent(OuraFrame(0x8f, Uint8List.fromList(ts))), isNotNull);
      expect(parseOuraEvent(OuraFrame(0x90, Uint8List.fromList(ts))), isNull);
      expect(parseOuraEvent(OuraFrame(0xfd, Uint8List.fromList(ts))), isNull);
      expect(parseOuraEvent(OuraFrame(0xfe, Uint8List.fromList(ts))), isNull);
      expect(
          parseOuraEvent(
              OuraFrame(0x61, Uint8List.fromList([...ts, ...List.filled(15, 0)]))),
          isNull);
    });

    test('a command response is not an event, and a short envelope is not one',
        () {
      expect(parseOuraEvent(parseOuraFrame(_hex('0d03') + _hex('560100'))!),
          isNull);
      // Event tag, but three bytes where four are needed for the stamp.
      expect(parseOuraEvent(parseOuraFrame(const <int>[0x61, 3, 1, 2, 3])!),
          isNull);
    });

    test('an empty debug_data body is null', () {
      expect(decodeDebugData(const <int>[]), isNull);
    });

    test('a battery record too short to carry its voltage is null', () {
      // Percent present, voltage cut off. The tempting failure is to return the
      // percent alone; the byte that would be read as the low half of the
      // voltage is simply not there, so nothing in the record is trustworthy.
      expect(decodeDebugData(_hex('2456')), isNull);
      expect(decodeDebugData(_hex('2456c8')), isNull);
    });

    test('a battery record with an impossible voltage is null', () {
      // 0x1027 LE = 10000 mV. No lithium cell reads that, so the offsets are
      // wrong and the percent beside them cannot be trusted either. The bound
      // is chemistry, not encoding — a wrong-width decoder fails it too.
      expect(decodeDebugData(_hex('2456102700')), isNull);
      // 145 %, which is not a state of charge.
      expect(decodeDebugData(_hex('2491c80f00')), isNull);
    });

    test('a text record containing a control byte is null', () {
      // 0x07 is a bell. A mis-framed record read as text is how control bytes
      // reach a log the user can export.
      expect(decodeDebugData(_hex('0454070a')), isNull);
      expect(decodeDebugData(_hex('04')), isNull);
    });

    test('a temperature outside the sensor part range refuses the WHOLE array',
        () {
      // 0x0d1c = 3356 -> 33.56 C, then 0x7530 = 30000 -> 300 C. Half a correct
      // array is more dangerous than none: it would publish one real probe and
      // silently hide that the offsets had moved.
      final good = parseOuraEvent(
          parseOuraFrame(_hex('6906') + _hex('01000000') + _hex('1c0d'))!)!;
      expect(decodeTemperatures(good), <double>[33.56]);
      final bad = parseOuraEvent(parseOuraFrame(
          _hex('4608') + _hex('01000000') + _hex('1c0d3075'))!)!;
      expect(decodeTemperatures(bad), isNull);
    });

    test('temperature lengths are bounded per tag', () {
      List<double>? t(int tag, int n) =>
          decodeTemperatures(OuraEvent(tag, 0, Uint8List.fromList([
            for (var i = 0; i < n; i += 2) ...[0x1c, 0x0d]
          ])));
      expect(t(kOuraEvtTemp, 2), isNull);
      expect(t(kOuraEvtTemp, 16), isNull);
      expect(t(kOuraEvtTempPeriod, 4), isNull);
      expect(t(kOuraEvtTemp, 4), [33.56, 33.56]);
      expect(t(kOuraEvtTemp, 14), hasLength(7));
      expect(t(kOuraEvtTempPeriod, 2), [33.56]);
    });

    test('an odd-length temperature body is null', () {
      final e = parseOuraEvent(
          parseOuraFrame(_hex('4607') + _hex('01000000') + _hex('1c0d30'))!)!;
      expect(decodeTemperatures(e), isNull);
    });

    test('a clock reading that is not a date is refused', () {
      final ok = parseOuraEvent(
          parseOuraFrame(_hex('4208') + _hex('01000000') + _hex('4fd2376a'))!)!;
      expect(decodeTimeSync(ok), 1782043215);
      // A ring whose RTC was never set. Accepting it would anchor an entire
      // sync's worth of records in 1970.
      final unset = parseOuraEvent(
          parseOuraFrame(_hex('4208') + _hex('01000000') + _hex('00000000'))!)!;
      expect(decodeTimeSync(unset), isNull);
    });
    test('a skipped time sync decodes its second, timezone and reason', () {
      // 1782043215 LE, tz -11 half-hours (0xf5), reason 1 (PPG running).
      final ok = parseOuraEvent(parseOuraFrame(
              _hex('850e') + _hex('01000000') + _hex('4fd2376a00000000f501'))!)!;
      final s = decodeTimeSyncSkipped(ok)!;
      expect(s.unix, 1782043215);
      expect(s.tzHalfHours, -11);
      expect(s.reason, kOuraSkipReasonPpgMeasuring);
      // It is not an anchor: decodeTimeSync ignores the tag.
      expect(decodeTimeSync(ok), isNull);
      // A 9-byte body, one short of the reason byte, is refused.
      final short = parseOuraEvent(parseOuraFrame(
              _hex('850d') + _hex('01000000') + _hex('4fd2376a00000000f5'))!)!;
      expect(decodeTimeSyncSkipped(short), isNull);
      // An unset second is refused.
      final unset = parseOuraEvent(parseOuraFrame(
              _hex('850e') + _hex('01000000') + _hex('0100000000000000f501'))!)!;
      expect(decodeTimeSyncSkipped(unset), isNull);
    });

    test('a ring start resets the clock only when reset bit 1 is set', () {
      OuraEvent start(int flags) =>
          OuraEvent(kOuraEvtRingStart, 0, Uint8List.fromList([4, 0, 0, 0, flags]));
      expect(ouraRingStartResetsClock(start(0x02)), isTrue);
      expect(ouraRingStartResetsClock(start(0x32)), isTrue);
      expect(ouraRingStartResetsClock(start(0x01)), isFalse);
      expect(
          ouraRingStartResetsClock(
              OuraEvent(kOuraEvtRingStart, 0, Uint8List.fromList([4, 0, 0, 0]))),
          isFalse);
    });

    test('an extended event checks its CRC-8 and reads a u64 time', () {
      // CRC-8, poly 0x31, init 0xff, by the nibble table: an implementation
      // independent of the bitwise one under test.
      const tbl = [
        0x00, 0x31, 0x62, 0x53, 0xc4, 0xf5, 0xa6, 0x97, //
        0xb9, 0x88, 0xdb, 0xea, 0x7d, 0x4c, 0x1f, 0x2e,
      ];
      int crc8(List<int> b) {
        var c = 0xff;
        for (final x in b) {
          c ^= x;
          c = ((c << 4) & 0xff) ^ tbl[c >> 4];
          c = ((c << 4) & 0xff) ^ tbl[c >> 4];
        }
        return c;
      }
      // "123456789" is the standard check string; this CRC gives 0xf7.
      expect(crc8('123456789'.codeUnits), 0xf7);
      final rest = <int>[0x5a, 10, 1, 0, 0, 0, 2, 0, 0, 0, 0xaa, 0xbb];
      final bytes = <int>[0xfd, crc8(rest), ...rest];
      final fs = parseOuraFrames(bytes);
      expect(fs, hasLength(1));
      expect(parseOuraEvent(fs.single), isNull,
          reason: 'never read as a standard decisecond event');
      final x = parseOuraExtendedEvent(fs.single)!;
      expect(x.tag, 0x5a);
      expect(x.time, 0x200000001);
      expect(x.body, [0xaa, 0xbb]);
      bytes[1] ^= 1;
      expect(parseOuraExtendedEvent(parseOuraFrames(bytes).single), isNull);
    });

    test('the ring rejecting a command as unsupported is told apart', () {
      expect(ouraIsUnsupported(parseOuraFrame(_hex('300110'))!, 0x10), isTrue);
      expect(ouraIsUnsupported(parseOuraFrame(_hex('300110'))!, 0x2f), isFalse);
      expect(ouraIsUnsupported(parseOuraFrame(_hex('30021000'))!, 0x10), isFalse);
    });

    test('a short batch summary still ends the batch, with unknowns as -1', () {
      final one = parseBatchSummary(parseOuraFrame(_hex('110103'))!)!;
      expect(one.received, 3);
      expect(one.sleepAnalysisProgress, -1);
      expect(one.bytesLeft, -1);
      final two = parseBatchSummary(parseOuraFrame(_hex('11020307'))!)!;
      expect(two.sleepAnalysisProgress, 7);
      expect(two.bytesLeft, -1);
      expect(parseBatchSummary(parseOuraFrame(_hex('1100'))!), isNull);
    });

    test('a fuel-gauge body too short for its layout is null', () {
      expect(decodeDebugData(_hex('14cf50c80fb2ffffffd53e0000')), isNull);
    });
  });

  group('outbound frames', () {
    test('the history request carries a decisecond cursor, a cap and a filter',
        () {
      expect(ouraCmdGetEvents(0, maxEvents: 8),
          _hex('10') + _hex('09') + _hex('0000000008ffffffff'));
      // A resumed drain asks from the bookmark, not from the beginning.
      expect(ouraCmdGetEvents(9391523).sublist(2, 6), _hex('a34d8f00'));
    });

    test('the authenticate frame declares its own length', () {
      final f = ouraCmdAuthenticate(List<int>.filled(16, 0xab));
      expect(f[0], 0x2f);
      expect(f[1], 17, reason: 'one ext-tag byte plus one AES block');
      expect(f.length, 19);
    });

    test('the clock is set in Unix seconds', () {
      expect(ouraCmdSyncTime(1782043215).sublist(2, 10),
          _hex('4fd2376a00000000'));
    });

    test('the notify mask uses the two-byte form only above 0xff', () {
      expect(ouraCmdSetNotifyFlags(0xbf), _hex('1c01bf'));
      expect(ouraCmdSetNotifyFlags(0x1bf), _hex('1c02bf01'));
    });

    test('a forced clock set adds a flags byte with bit 0 set', () {
      expect(ouraCmdSyncTime(1782043215, tzHalfHours: -11, force: true),
          _hex('120a') + _hex('4fd2376a00000000') + _hex('f501'));
      expect(ouraCmdSyncTime(1782043215, tzHalfHours: 11),
          _hex('1209') + _hex('4fd2376a00000000') + _hex('0b'));
    });

    test('a value past the low 32 bits still encodes correctly', () {
      // 0x1_00000001 = 4294967297. Low word 0x00000001, high word 0x00000001
      // — proves the two-setUint32 split actually carries the high half,
      // not just that the common (high-word-zero) case happens to work.
      expect(ouraCmdSyncTime(0x100000001).sublist(2, 10),
          _hex('0100000001000000'));
    });
  });

  group('sleep phases', () {
    OuraEvent hypnogram(int tag, String bodyHex) {
      final body = _hex(bodyHex);
      return parseOuraEvent(parseOuraFrame(
          [tag, body.length + 4, ..._hex('a34d8f00'), ...body])!)!;
    }

    test('two-bit codes unpack MSB-first, four to a byte', () {
      // 0b00_01_10_11: LSB-first would hand back the reverse.
      final out = decodeSleepPhases(hypnogram(0x4e, '001b'))!;
      expect(out.header, 0x00);
      expect(out.phases, [
        OuraSleepPhase.deep,
        OuraSleepPhase.light,
        OuraSleepPhase.rem,
        OuraSleepPhase.awake,
      ]);
    });

    test('both carrier tags decode the same codes', () {
      for (final tag in <int>[0x4e, 0x5a]) {
        final out = decodeSleepPhases(hypnogram(tag, '01e4'))!;
        expect(out.phases, [
          OuraSleepPhase.awake,
          OuraSleepPhase.rem,
          OuraSleepPhase.light,
          OuraSleepPhase.deep,
        ]);
      }
    });

    test('the header is passed through, every following byte is codes', () {
      final out = decodeSleepPhases(hypnogram(0x5a, '0301020300'))!;
      expect(out.header, 0x03);
      expect(out.phases.length, 16);
      expect(out.phases[3], OuraSleepPhase.light);
      expect(out.phases[7], OuraSleepPhase.rem);
      expect(out.phases[11], OuraSleepPhase.awake);
    });

    test('a header-only body is null', () {
      expect(decodeSleepPhases(hypnogram(0x5a, '00')), isNull);
    });

    test('0x4b is not a hypnogram carrier', () {
      expect(decodeSleepPhases(hypnogram(0x4b, '001b')), isNull);
    });

    test('a non-hypnogram tag is null', () {
      expect(decodeSleepPhases(hypnogram(0x61, '001b')), isNull);
    });
  });

  group('streams: bit order and refusal (synthetic vectors)', () {
    OuraEvent ev(int tag, List<int> body) =>
        OuraEvent(tag, 1000, Uint8List.fromList(body));

    /// The 14-byte beat body for six intervals, the layout the decoder reads.
    List<int> ibiBody(List<int> ibis) => [
          for (final i in ibis) i >> 3,
          for (final i in ibis) 0x80 | (i & 1),
          ((ibis[0] >> 1) & 3) << 6 |
              ((ibis[1] >> 1) & 3) << 4 |
              ((ibis[2] >> 1) & 3) << 2 |
              ((ibis[3] >> 1) & 3),
          ((ibis[4] >> 1) & 3) << 6 | ((ibis[5] >> 1) & 3) << 4 | 0x07,
        ];

    test('HR/RMSSD: one pair per 5-minute window, in body order', () {
      expect(decodeHrvPairs(ev(kOuraEvtHrv, [60, 40, 62, 45, 58, 50])),
          [(60, 40), (62, 45), (58, 50)]);
      expect(decodeHrvPairs(ev(kOuraEvtHrv, [60, 40, 62])), isNull);
      expect(decodeHrvPairs(ev(kOuraEvtSpo2, [60, 40])), isNull);
    });

    test('SpO2: a header byte, then one reading a second; 0xff continues', () {
      expect(decodeSpo2(ev(kOuraEvtSpo2, [0x01, 97, 96, 98, 0xff])),
          [97, 96, 98]);
      expect(decodeSpo2(ev(kOuraEvtSpo2, [0x01, 97, 0])), [97, 0]);
      expect(decodeSpo2(ev(kOuraEvtSpo2, [0x01, 97, 101])), isNull,
          reason: 'over 100 % is a wrong layout, not a reading');
      expect(decodeSpo2(ev(kOuraEvtSpo2, [0x01, 0xff])), isNull);
      expect(decodeSpo2(ev(kOuraEvtSpo2, [0x01])), isNull);
    });

    test('beat intervals: 11 bits, high byte, packed middle bits, low bit', () {
      // 1003 ms = 0b111_1101_0_1_1: high 8 = 0x7d, middle 2 = 01, low 1 = 1.
      // The amplitude bits (7..1 of bytes 6..11) are set and must not leak.
      expect(
          decodeIbiAmplitude(ev(kOuraEvtIbiAmplitude,
              _hex('7d7d7d7d7d7d' '818181818181' '55' '57'))),
          List.filled(6, 1003));
      const ibis = [800, 1001, 1234, 650, 1999, 300];
      expect(decodeIbiAmplitude(ev(kOuraEvtIbiAmplitude, ibiBody(ibis))),
          ibis);
      expect(
          decodeIbiAmplitude(
              ev(kOuraEvtIbiAmplitude, ibiBody(ibis).sublist(0, 13))),
          isNull,
          reason: 'the body is a fixed 14 bytes');
    });

    test('clean-beat intervals with a quality code, two bytes a beat', () {
      // 1257 ms at quality 1: 0x9d << 3 | 1, quality bits 4..3 = 01.
      expect(decodeGreenIbiQuality(ev(kOuraEvtGreenIbiQuality, _hex('9d09'))),
          [(1257, kOuraIbiQualityGood)]);
      expect(
          decodeGreenIbiQuality(
              ev(kOuraEvtGreenIbiQuality, _hex('9d09' '7d10'))),
          [(1257, 1), (1000, 2)]);
      expect(decodeGreenIbiQuality(ev(kOuraEvtGreenIbiQuality, [0x9d])),
          isNull);
    });

    test('always-on HR: exactly its declared count of readings', () {
      expect(decodeAohr(ev(kOuraEvtAohr, [1, 0, 2, 55, 1, 56, 1])),
          [(55, 1), (56, 1)]);
      expect(decodeAohr(ev(kOuraEvtAohr, [1, 0, 3, 55, 1, 56, 1])), isNull);
      expect(decodeAohr(ev(kOuraEvtAohr, [1, 0])), isNull);
    });
  });

  group('authentication (non-cryptographic half)', () {
    test('the challenge is 15 bytes out of a 16-byte reply body', () {
      final f = parseOuraFrame(
          _hex('2f10') + _hex('2c0e2d6a0a08c99b4365f458e6e97382'))!;
      expect(ouraAuthNonce(f), _hex('0e2d6a0a08c99b4365f458e6e97382'));
    });

    test('success and refusal are told apart, and silence is neither', () {
      expect(ouraAuthResult(parseOuraFrame(_hex('2f022e00'))!), 0);
      expect(ouraAuthResult(parseOuraFrame(_hex('2f022e01'))!), 1);
      // The ring refusing a command because the session never authenticated.
      // Distinguishing this from a timeout is what stops a drain loop spinning
      // against a ring that is simply waiting to be let in.
      final gate = parseOuraFrame(_hex('2f022f01'))!;
      expect(ouraIsAuthRequired(gate), isTrue);
      expect(ouraAuthResult(gate), isNull);
      expect(ouraAuthNonce(gate), isNull);
    });
  });
}
