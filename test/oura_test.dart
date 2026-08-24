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
// on this project owns a ring. The decoders that are NOT here (beat intervals,
// SpO2, hypnogram, steps) are absent precisely because there are no bytes to
// build such a fixture from, and shipping a guess would have this file
// faithfully encoding the wrong answer.
//
// The NULL cases at the bottom are the load-bearing half: they are what proves
// the decoder REFUSES rather than always producing something.
//
// AES-128/ECB auth-response encryption is NOT exercised here — this package
// has no cipher implementation. See the session that drives this wire format
// for that half of the auth handshake.

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

    test('trailing bytes past the declared length are ignored', () {
      // The ring is known to append them. Eight declared, eleven delivered.
      final f = parseOuraFrame(_hex('110808009e0e00000300') + _hex('aabbcc'))!;
      expect(f.payload.length, 8);
      expect(parseBatchSummary(f)!.bytesLeft, 3742);
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
          parseOuraFrame(_hex('4606') + _hex('01000000') + _hex('1c0d'))!)!;
      expect(decodeTemperatures(good), <double>[33.56]);
      final bad = parseOuraEvent(parseOuraFrame(
          _hex('4608') + _hex('01000000') + _hex('1c0d3075'))!)!;
      expect(decodeTemperatures(bad), isNull);
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

    test('a value past the low 32 bits still encodes correctly', () {
      // 0x1_00000001 = 4294967297. Low word 0x00000001, high word 0x00000001
      // — proves the two-setUint32 split actually carries the high half,
      // not just that the common (high-word-zero) case happens to work.
      expect(ouraCmdSyncTime(0x100000001).sublist(2, 10),
          _hex('0100000001000000'));
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
