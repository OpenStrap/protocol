// gen5 (WHOOP 5) historical-record decoder tests — v18/v20/v21/v26.
//
// The v18 and v26 fixtures below are REAL captures, independently
// byte-verified (CRC16-modbus header + CRC32 payload both check out; every
// decoded field cross-checked by hand against the multiband port spec's §1.5
// claims, which themselves come from two independent hardware-tested
// reference implementations). The v20/v21 cases are synthetic — no full real
// capture was available for this task — but exercise the exact
// byte-verified offsets/scales from §1.5, so they validate the arithmetic
// even without a real fixture.

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// The 24 saturated i16 deltas carried by the real v26 fixture used below
/// (inner[19:67], body 6).
const List<int> _v26Deltas = [
  -1432,
  -1332,
  -1139,
  -954,
  -629,
  -436,
  -326,
  -294,
  -147,
  -170,
  -43,
  -5,
  -201,
  -918,
  -1563,
  -1833,
  -1313,
  -930,
  -616,
  -293,
  -422,
  -380,
  -235,
  -164,
];

Uint8List hex(String s) {
  final clean = s.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('parseGen5Historical — v18 (real fixture)', () {
    // aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b
    // 0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7
    // 000901f10b0007010c020c00000000000000000000000000000000000000000000000
    // 100656f1e1e0000009d61a7c00000003e862817
    // A "worn" capture, unix=1780916150 — CRC16+CRC32 both verified.
    final frame = hex(
      'aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000'
      '000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000'
      '000000000000f7000901f10b0007010c020c000000000000000000000000000'
      '00000000000000000000100656f1e1e0000009d61a7c00000003e862817',
    );

    late Gen5HistorySample sample;

    setUp(() {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue, reason: 'both gen5 CRCs must check out');
      final r = parseGen5Historical(parsed.inner);
      expect(r, isA<Gen5HistorySample>());
      sample = r as Gen5HistorySample;
    });

    test('shared header', () {
      expect(sample.histVersion, 18);
      expect(sample.recordIndex, 25443699);
      expect(sample.unix, 1780916150);
    });

    test('heart rate + RR', () {
      expect(sample.heartRate, 102);
      expect(sample.rrCount, 2);
      expect(sample.rrIntervalsMs, [602, 613]);
    });

    test('quality flags stay raw; alt-HR is gated, never substituted', () {
      expect(sample.hrQualityFlags, 0x8D);
      expect(sample.hrQualityCounter, 0x0D); // low 4 bits, separate field
      // inner[29] rides along raw; bit7 gates the corroborated read only.
      expect(sample.heartRateAlt, 101);
      expect(sample.hrRrValidThisSecond, isTrue);
      expect(sample.trustedHeartRateAlt, 101);
      // bit7 is NOT "HR valid": heartRate stands on its own range check and
      // is present on plenty of records with bit7 clear.
    });

    test('frame-abs 36/37 is NOT one fixed-point HR', () {
      // Read as one u16 this fixture gives 0x658D/256 = 101.55 bpm against
      // heartRate 102 — and the ".55" is just bit7 of byte 36.
      //
      // bit4 is never set on any observed record, which a fractional byte
      // could not manage.
      expect(sample.hrQualityFlags & 0x10, 0);

      // And even with bit7 set, the second HR byte disagrees with heartRate
      // by a full bpm — it is a corroboration signal, not a duplicate.
      expect(sample.heartRateAlt, isNot(sample.heartRate));
    });

    test('motion: gravity is unit magnitude, dynamic accel small', () {
      expect(sample.gravityG[0], closeTo(-0.7252, 1e-3));
      expect(sample.gravityG[1], closeTo(0.4944, 1e-3));
      expect(sample.gravityG[2], closeTo(0.4969, 1e-3));
      final mag = sample.gravityG.map((g) => g * g).reduce((a, b) => a + b);
      expect(mag, closeTo(1.0, 0.05));
      expect(sample.dynamicAccelerationG, closeTo(0.00916, 1e-3));
    });

    test('steps + activity', () {
      expect(sample.stepMotionCounter, 50);
      expect(sample.stepCadence, 170);
      expect(sample.activityClass, 0); // unknown/unclassified, NOT "still"
    });

    test('temperature (gen5-specific scales)', () {
      expect(sample.tempAux1C, closeTo(24.7, 1e-6));
      expect(sample.tempAux2C, closeTo(26.5, 1e-6));
      expect(sample.skinTempC, closeTo(30.57, 1e-6));
    });

    test('optical front-end: four independent bytes, not two u16s', () {
      // Body 85..88: two u8 quantized PD means, then two SIGNED i8
      // per-detector pSNR values in dB (-128 = unavailable).
      expect(sample.pdMeanB, 0x65);
      expect(sample.pdMeanA, 0x6F);
      expect(sample.psnrB, 0x1E); // +30 dB
      expect(sample.psnrA, 0x1E);
      expect(sample.psnrBAvailable, isTrue);
      expect(sample.psnrAAvailable, isTrue);
      expect(sample.isOpticalAmpSentinel, isFalse); // not both-unavailable
      // One compat assertion so the deprecated u16 view stays wired correctly.
      // ignore: deprecated_member_use_from_same_package
      expect(sample.opticalBaseline, 0x656F);
    });

    test('experimental fields exposed raw, not fabricated', () {
      // frame-abs 40: still unnamed, and the whoop-rs `>=192` gate passes
      // 96.7% of records, so no anomaly gate is wired off it. 255 is the
      // modal value.
      expect(sample.cardiacStatusRaw, 255);
      // frame-abs 82 is not SpO2 — zero in 99% of records and nonzero only
      // during band-declared sleep. This fixture is awake, so it reads 0.
      expect(sample.spo2CandidateRaw, 0);
      // ignore: deprecated_member_use_from_same_package
      expect(sample.spo2Candidate, isNull);
    });

    test('band sleep state: this fixture is awake', () {
      expect(sample.sleepStateByte, 0);
      expect(sample.sleepStateRawNibble, 0);
      expect(sample.sleepState, Gen5SleepState.wake);
    });
  });

  group('parseGen5Historical — v18 sleep_state nibble ordering', () {
    // Same real v18 fixture, with frame-abs 81 (inner[73]) overridden to each
    // of the four nibble values. Ordering (0 wake / 1 still / 2 sleep / 3 up)
    // was resolved on 400,000 records from two bands: mean dynamic
    // acceleration runs 0.0773 / 0.0255 / 0.0104 / 0.0504 g and median heart
    // rate 88 / 76 / 60 / 77 bpm across nibbles 0..3, so nibble 0 is the
    // highest-motion, highest-HR state (it cannot be "still") and nibble 2 is
    // the lowest of both. whoop-rs's "0 still / 1 wake" is reversed.
    final frame = hex(
      'aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000'
      '000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000'
      '000000000000f7000901f10b0007010c020c000000000000000000000000000'
      '00000000000000000000100656f1e1e0000009d61a7c00000003e862817',
    );

    Gen5HistorySample decodeWithNibble(int nibble) {
      final inner = Uint8List.fromList(
        parseFrame(frame, profile: BandProfile.gen5)!.inner,
      );
      // Preserve the low bits (on-wrist, wake_quality) — only bits 4-5 move.
      inner[73] = (inner[73] & 0x0F) | (nibble << 4);
      return parseGen5Historical(inner) as Gen5HistorySample;
    }

    test('each nibble maps to its named state', () {
      expect(decodeWithNibble(0).sleepState, Gen5SleepState.wake);
      expect(decodeWithNibble(1).sleepState, Gen5SleepState.still);
      expect(decodeWithNibble(2).sleepState, Gen5SleepState.sleep);
      expect(decodeWithNibble(3).sleepState, Gen5SleepState.up);
    });

    test('the nibble is masked to 2 bits and never overruns the enum', () {
      for (int b = 0; b <= 255; b++) {
        final inner = Uint8List.fromList(
          parseFrame(frame, profile: BandProfile.gen5)!.inner,
        );
        inner[73] = b;
        final s = parseGen5Historical(inner) as Gen5HistorySample;
        expect(s.sleepStateRawNibble, (b >> 4) & 0x03);
        expect(s.sleepState, Gen5SleepState.values[(b >> 4) & 0x03]);
        expect(s.onWristRaw, b & 0x03);
        expect(s.wakeQualityRaw, (b >> 2) & 0x03);
      }
    });
  });

  group('parseGen5Historical — v26 (real fixture)', () {
    // aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc
    // 8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84f
    // e15ff5cff405fb33c50080101006cb67c17
    // unix=1780917232 — CRC16+CRC32 both verified.
    final frame = hex(
      'aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46f'
      'c8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe8'
      '4fe15ff5cff405fb33c50080101006cb67c17',
    );

    test('decodes record_index as the shared u32, not a truncated u16', () {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue);
      final r = parseGen5Historical(parsed.inner);
      expect(r, isA<Gen5PpgWaveform>());
      final wf = r as Gen5PpgWaveform;
      expect(wf.histVersion, 26);
      // Same u32 counter every other version uses. A u16 read truncates to
      // 16813 and wraps every ~18h; inner[5:7] is this value's high half, not
      // a separate field.
      expect(wf.recordIndex, 25444781);
      expect(wf.unix, 1780917232);
      // ignore: deprecated_member_use_from_same_package
      expect(wf.rawByte19, 174);
      expect(wf.pipStateCounter, 1);
      // These 24 i16s are DELTAS over a 25-sample window (body 6), not
      // samples — see `reconstructs a 25-sample window` below for the
      // absolute codes they step through.
      expect(wf.opticalDeltas, _v26Deltas);
    });

    test('record_index is one consecutive u32 across real consecutive frames',
        () {
      final hexes = [
        'aa015000010035412f1a80cdbb7601e700556a33',
        'aa015000010035412f1a80cebb7601e800556a33',
        'aa015000010035412f1a80cfbb7601e900556a33',
      ];
      // The full u32 is consecutive; inner[5:7] is its high half, constant
      // across the capture, not a separate field. A u16 read yields only the
      // low half (48077..48079), which wraps every ~18h.
      final expectedIds = [24558541, 24558542, 24558543];
      final expectedUnix = [1783955687, 1783955688, 1783955689];
      for (var i = 0; i < hexes.length; i++) {
        // Truncated capture excerpts — header + record_index/unix only, enough
        // to exercise the shared header parse without the full v26 payload.
        final inner = hex(hexes[i]).sublist(8); // strip the 8-byte gen5 header
        final hdr = Gen5HistoricalHeader.tryParse(inner);
        expect(hdr, isNotNull);
        expect(hdr!.version, 26);
        expect(hdr.recordIndex, expectedIds[i]);
        expect(hdr.recordIndex >> 16, 374); // shared high half
        expect(hdr.unix, expectedUnix[i]);
      }
      // Counter and clock advance together — the two fixtures below are a
      // v18/v26 pair from one session, so the counter cannot be per-version.
      expect(
          expectedIds[2] - expectedIds[0], expectedUnix[2] - expectedUnix[0]);
    });
  });

  group('parseGen5Historical — v26 per-record metadata', () {
    // The same real v26 fixture as above.
    final frame = hex(
      'aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46f'
      'c8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe8'
      '4fe15ff5cff405fb33c50080101006cb67c17',
    );

    Gen5PpgWaveform decode(Uint8List f) {
      final parsed = parseFrame(f, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue);
      return parseGen5Historical(parsed.inner) as Gen5PpgWaveform;
    }

    test('frame-abs 19 is a u16, and the old byte read loses the high half',
        () {
      final wf = decode(frame);
      expect(wf.segmentId, 18350);
      // The deprecated byte read returns 18350 & 0xFF — the high byte (71)
      // is discarded. On real records that byte is nonzero 99% of the time.
      // ignore: deprecated_member_use_from_same_package
      expect(wf.rawByte19, 174);
      // ignore: deprecated_member_use_from_same_package
      expect(wf.rawByte19, wf.segmentId & 0xFF);
      expect(wf.segmentId >> 8, isNonZero);
    });

    test('segmentId is an integer 0..99 packed as a Q15 fraction', () {
      final wf = decode(frame);
      expect(wf.segmentIndex, 56);
      expect((56 * 32768) ~/ 100, wf.segmentId);
    });

    test('the PIP body decodes per the revision-26 field map', () {
      final wf = decode(frame);
      // body 0 / inner[13:15] — PIP state/segment counter, a u16.
      expect(wf.pipStateCounter, 1);
      // body 2 / inner[15:19] — the window's first optical ADC code, i32 LE
      // (bytes c3 c5 05 00). Inside the front end's signed 20-bit range.
      expect(wf.firstSampleAdc, 378307);
      expect(wf.firstSampleAdcInRange, isTrue);
      expect(wf.firstSampleAdcOrNull, 378307);
      // body 54 / inner[67:71] — max adjacent accel-magnitude delta in g. The
      // SAME f32 as R18's dynamicAccelerationG (verified byte-for-byte on
      // every paired record).
      expect(wf.accelDeltaG, closeTo(0.0219, 1e-4));
      // body 58 / inner[71:73] — packed channel-0 processing-state word, one
      // u16 (== R18 statusWord on every paired record).
      expect(wf.channelStateWord, 2128);
      // body 60 / inner[73] — primary-flags bit-8 snapshot.
      expect(wf.primaryFlagsByte, 1);
      expect(wf.primaryFlagsBit8Raw, 1);
      // body 61 / inner[74] — binary waveform-morphology acceptance result.
      expect(wf.morphologyByte, 1);
      expect(wf.morphologyPass, isTrue);
      // body 62 / inner[75] — aligned tail, outside the copied ring record.
      expect(wf.alignedTailByte, 0);
    });

    test('a morphology byte other than 1 is not a pass', () {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      for (final b in [0x00, 0x02, 0xFF]) {
        final inner = Uint8List.fromList(parsed.inner);
        inner[74] = b;
        final wf = parseGen5Historical(inner) as Gen5PpgWaveform;
        expect(wf.morphologyByte, b); // raw byte preserved
        expect(wf.morphologyPass, isFalse);
      }
    });

    test('the first sample is a signed i32, not four independent bytes', () {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      // A negative first sample sign-extends into inner[17]/inner[18]. The old
      // decoder read inner[17] as a 0..7 "sub-channel" and called 0xFD..0xFF
      // (~0.2% of records) outliers; they are simply negative codes.
      final inner = Uint8List.fromList(parsed.inner);
      inner.setRange(15, 19, [0x0A, 0xBB, 0xFD, 0xFF]); // -148726
      final wf = parseGen5Historical(inner) as Gen5PpgWaveform;
      expect(wf.firstSampleAdc, -148726);
      expect(wf.firstSampleAdcInRange, isTrue);
      // ignore: deprecated_member_use_from_same_package
      expect(wf.subChannel, 0xFD); // the "outlier" the old reading saw
    });

    test('an impossible first sample is exposed raw, not fabricated', () {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      final inner = Uint8List.fromList(parsed.inner);
      inner.setRange(15, 19, [0x00, 0x00, 0x40, 0x00]); // 4194304 > 2^19-1
      final wf = parseGen5Historical(inner) as Gen5PpgWaveform;
      // The record still decodes — the raw value stays visible as itself.
      expect(wf.firstSampleAdc, 4194304);
      // But it is not offered as a code the front end could have produced.
      expect(wf.firstSampleAdcInRange, isFalse);
      expect(wf.firstSampleAdcOrNull, isNull);
      // And the reconstruction reports it rather than silently summing on.
      expect(wf.reconstructWindow().outOfRangeSampleIndices, contains(0));
      expect(wf.reconstructWindow().divergenceProven, isTrue);
    });

    test('reconstructs a 25-sample window from first sample + 24 deltas', () {
      final wf = decode(frame);
      final r = wf.reconstructWindow();
      expect(r.samples.length, 25);
      expect(r.samples.first, wf.firstSampleAdc);
      // Cumulative sum: sample i+1 == sample i + delta i.
      for (var i = 0; i < _v26Deltas.length; i++) {
        expect(r.samples[i + 1], r.samples[i] + _v26Deltas[i]);
      }
      expect(r.samples.last, 362532);
      // This real record is clean: no saturated delta, nothing impossible.
      expect(r.hasSaturatedDelta, isFalse);
      expect(r.firstAmbiguousSampleIndex, isNull);
      expect(r.outOfRangeSampleIndices, isEmpty);
      expect(r.divergenceProven, isFalse);
      expect(r.trustedSampleCount, 25);
      expect(r.trustedSamples, r.samples);
    });

    test('a -32768 delta marks its sample and everything after it ambiguous',
        () {
      // Delta reconstruction is lossy: the saturating clamp destroys its
      // operand, and the wire carries no signal that it happened.
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      final inner = Uint8List.fromList(parsed.inner);
      // Delta 3 lives at inner[19 + 2*3] = inner[25:27].
      inner[25] = 0x00;
      inner[26] = 0x80; // -32768 LE
      final wf = parseGen5Historical(inner) as Gen5PpgWaveform;
      expect(wf.opticalDeltas[3], -32768);
      final r = wf.reconstructWindow();
      expect(r.hasSaturatedDelta, isTrue);
      // Delta 3 produces sample 4, so samples 0..3 survive and 4..24 do not.
      expect(r.firstAmbiguousSampleIndex, 4);
      expect(r.trustedSampleCount, 4);
      expect(r.trustedSamples, r.samples.sublist(0, 4));
      // The window still reconstructs — it is approximate, not withheld.
      expect(r.samples.length, 25);
    });

    test('+32767 is a rail too — the positive clamp is just as ambiguous', () {
      // A delta of exactly +32767 is the positive i16 saturation rail: real
      // windows hit it exactly, with nothing anywhere near it below, so it is
      // a clamp, not a large step. Treating only -32768 as saturation handed
      // over a fabricated ramp as `trustedSampleCount == 25`.
      final r = reconstructSaturatedDeltaWindow(1000, [10, 32767, 10]);
      expect(r.hasSaturatedDelta, isTrue);
      expect(r.firstAmbiguousSampleIndex, 2);
      expect(r.trustedSampleCount, 2);
      // One rail off is still an ordinary delta.
      final near = reconstructSaturatedDeltaWindow(1000, [10, 32766, -10]);
      expect(near.hasSaturatedDelta, isFalse);
      expect(near.trustedSampleCount, 4);
    });

    test('an out-of-range reconstructed sample proves the inversion diverged',
        () {
      // A correct inversion cannot land outside signed 20 bits, so a window
      // that does is provably wrong.
      final r = reconstructSaturatedDeltaWindow(524000, [200, 300, -100]);
      expect(r.samples, [524000, 524200, 524500, 524400]);
      expect(r.outOfRangeSampleIndices, [2, 3]); // 524500/524400 > 524287
      expect(r.divergenceProven, isTrue);
      expect(r.hasSaturatedDelta, isFalse); // independent of the clamp
    });

    test('the deprecated members map onto the real fields they misread', () {
      // Every name below is deprecated; the package's analysis_options mutes
      // deprecated_member_use_from_same_package precisely so these stay
      // testable. See the class for what each byte really is.
      final wf = decode(frame);
      expect(wf.burstIndex, wf.pipStateCounter & 0xFF);
      expect(wf.frontEndMetaRaw, wf.firstSampleAdc & 0xFFFF); // 50627
      expect(wf.subChannel, (wf.firstSampleAdc >> 16) & 0xFF); // 5
      expect(wf.subChannelKnown, 5); // "inside 0..7" only ever meant positive
      expect(wf.signalMetric, wf.accelDeltaG);
      expect(wf.gainSetting, wf.channelStateWord & 0xFF); // 80
      expect(wf.gainIndex, (wf.channelStateWord >> 8) & 0xFF); // 8
      expect(wf.flagA, wf.primaryFlagsByte);
      expect(wf.flagB, wf.morphologyByte);
      expect(wf.ppgWaveform, wf.opticalDeltas); // deltas, never samples
    });

    test('a record short of the exact 76-byte length is rejected outright', () {
      // v26's inner is exactly 76 bytes. A truncated one used to decode its
      // waveform with the trailing metadata nulled out; it is now rejected,
      // because a record that is not 76 bytes is not a v26 record and its
      // "waveform" is whatever bytes happened to arrive.
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.inner.length, 76);
      for (final len in [67, 75, 74]) {
        final short = Uint8List.fromList(parsed.inner.sublist(0, len));
        expect(parseGen5Historical(short), isNull, reason: 'len=$len');
      }
    });
  });

  group(
      'parseGen5Historical — v21 IMU deep buffer (structural, offsets from §1.5)',
      () {
    Uint8List buildV21({
      required int recordIndex,
      required int unix,
      List<int>? accelXRaw,
    }) {
      final inner = Uint8List(kGen5V21InnerLen);
      inner[0] = 0x2f;
      inner[1] = 21; // hist_version (informational only — not the real gate)
      inner[2] = 0x80; // layout_marker
      final v = ByteData.sublistView(inner);
      v.setUint32(3, recordIndex, Endian.little);
      v.setUint32(7, unix, Endian.little);
      v.setUint16(16, 100, Endian.little); // countA
      v.setUint16(622, 100, Endian.little); // countB
      final ax = accelXRaw ?? List.filled(100, 4096); // 4096/4096 = 1.0g
      for (int i = 0; i < 100; i++) {
        v.setInt16(20 + 2 * i, ax[i], Endian.little); // accelX
        v.setInt16(220 + 2 * i, 0, Endian.little); // accelY
        v.setInt16(420 + 2 * i, 0, Endian.little); // accelZ
        v.setInt16(632 + 2 * i, 16384, Endian.little); // gyroX raw
        v.setInt16(832 + 2 * i, 0, Endian.little); // gyroY
        v.setInt16(1032 + 2 * i, 0, Endian.little); // gyroZ
      }
      return inner;
    }

    test('is identified by shape (paired 100-sample counts), not hist_version',
        () {
      final inner = buildV21(recordIndex: 42, unix: 1780000000);
      final r = parseGen5Historical(inner);
      expect(r, isA<Gen5ImuBuffer>());
      final imu = r as Gen5ImuBuffer;
      expect(imu.recordIndex, 42);
      expect(imu.unix, 1780000000);
      expect(imu.countA, 100);
      expect(imu.countB, 100);
      expect(imu.accelXg.length, 100);
      expect(imu.accelXg.first, closeTo(1.0, 1e-9)); // 4096 * 1/4096
      expect(imu.accelYg.first, 0.0);
      expect(imu.gyroXdps.first, closeTo(16384 * (2000.0 / 32768.0), 1e-9));
    });

    test('a partly-filled block decodes only the samples it declares', () {
      final inner = buildV21(recordIndex: 1, unix: 1780000000);
      ByteData.sublistView(inner).setUint16(622, 40, Endian.little);
      final r = parseGen5Historical(inner) as Gen5ImuBuffer;
      // Accel block is still full; the gyro block declared 40, so decoding the
      // block's full capacity here would emit 60 samples of stale trailing
      // bytes as if they were real motion.
      expect(r.countB, 40);
      expect(r.accelXg, hasLength(100));
      expect(r.gyroXdps, hasLength(40));
      expect(r.gyroYdps, hasLength(40));
      expect(r.gyroZdps, hasLength(40));
    });

    test('rejects counts outside the block capacity', () {
      for (final bad in [0, 101]) {
        final inner = buildV21(recordIndex: 1, unix: 1780000000);
        ByteData.sublistView(inner).setUint16(622, bad, Endian.little);
        expect(parseGen5Historical(inner), isNull, reason: 'countB=$bad');
      }
    });

    test(
        'an otherwise-v21-shaped buffer at the wrong length is not misidentified',
        () {
      final short = Uint8List(kGen5V21InnerLen - 1);
      expect(const Gen5V21Decoder().matches(short), isFalse);
    });
  });

  group(
      'parseGen5Historical — v20 optical deep buffer (structural, offsets from §1.5)',
      () {
    Uint8List buildV20({required int recordIndex, required int unix}) {
      final inner = Uint8List(kGen5V20InnerLen);
      inner[0] = 0x2f;
      inner[1] = 20;
      inner[2] = 0x81; // layout_marker
      final v = ByteData.sublistView(inner);
      v.setUint32(3, recordIndex, Endian.little);
      v.setUint32(7, unix, Endian.little);
      // Block 0: active (25 samples), block 1/2 empty, block 3/4 active —
      // matches the reference corpus's observed sampleCount pattern.
      const blockLen = 422;
      const bodyStart = 18;
      final activeBlocks = {0, 3, 4};
      for (int b = 0; b < 5; b++) {
        final start = bodyStart + b * blockLen;
        final count = activeBlocks.contains(b) ? 25 : 0;
        inner[start] = count;
        final ch0 = start + 21;
        final ch1 = ch0 + 200;
        for (int i = 0; i < count; i++) {
          // sample = block*1000 + channel*100 + i, sign-extended 20-bit safe range
          v.setUint32(ch0 + 4 * i, b * 1000 + i, Endian.little);
          v.setUint32(ch1 + 4 * i, b * 1000 + 100 + i, Endian.little);
        }
      }
      return inner;
    }

    test('decodes 5 blocks, only 0/3/4 active, raw channel samples verbatim',
        () {
      final inner = buildV20(recordIndex: 11494060, unix: 1784054004);
      final r = parseGen5Historical(inner);
      expect(r, isA<Gen5OpticalBuffer>());
      final buf = r as Gen5OpticalBuffer;
      expect(buf.recordIndex, 11494060);
      expect(buf.unix, 1784054004);
      expect(buf.blocks.length, 5);
      expect(buf.blocks[0].activeSampleCount, 25);
      expect(buf.blocks[1].activeSampleCount, 0);
      expect(buf.blocks[2].activeSampleCount, 0);
      expect(buf.blocks[3].activeSampleCount, 25);
      expect(buf.blocks[4].activeSampleCount, 25);
      expect(buf.blocks[0].channel0, List.generate(25, (i) => i));
      expect(buf.blocks[0].channel1, List.generate(25, (i) => 100 + i));
      expect(buf.blocks[1].channel0, isEmpty);
    });

    test('a v20-length buffer with the wrong version byte is not matched', () {
      final inner = buildV20(recordIndex: 1, unix: 1780000000);
      inner[1] = 99;
      expect(parseGen5Historical(inner), isNull);
    });

    test('channel slot start offsets match both reference repos exactly', () {
      // whoop-rs's inner-relative offsets (39,239,1305,1505,1727,1927) — see
      // gen5_records.dart's derivation from the frame-absolute offsets
      // (47,247,1313,1513,1735,1935) noop states directly.
      const bodyStart = 18, blockLen = 422;
      int ch0(int b) => bodyStart + b * blockLen + 21;
      int ch1(int b) => ch0(b) + 200;
      expect(ch0(0), 39);
      expect(ch1(0), 239);
      expect(ch0(3), 1305);
      expect(ch1(3), 1505);
      expect(ch0(4), 1727);
      expect(ch1(4), 1927);
    });
  });

  group(
      'gen5 REALTIME_DATA (0x28) — proves the inner-relative offsets are gen-agnostic',
      () {
    test(
        'the real byte-verified fixture decodes via the existing parseRealtimeHr',
        () {
      // aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc
      final frame = hex(
          'aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc');
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue);
      final r = parseRealtimeHr(parsed.inner)!;
      expect(r.tsRaw, 1780916382);
      expect(r.hrBpm, 98);
      expect(r.rrMs, [603, 587]);
    });
  });

  group('gen5 METADATA HISTORY_END (0x31) — offset audit', () {
    test(
        'the real byte-verified fixture decodes meta_type/unix correctly (no gen5-specific code needed)',
        () {
      // aa011c00010023d1319102b949596a705d3b000000fdba010010000000000000f269faec
      final frame = hex(
          'aa011c00010023d1319102b949596a705d3b000000fdba010010000000000000f269faec');
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue);
      final m = parseMetadata(parsed.inner)!;
      expect(m.sub, 2);
      expect(m.name, 'HISTORY_END');
      // The independently-quoted "trim_cursor=113405" value falls out of this
      // decoder's EXISTING `token` field's first 4 bytes — no gen5-specific
      // offset change was needed. See control.dart's parseMetadata doc.
      expect(m.token, isNotNull);
      final trimCursor =
          ByteData.sublistView(m.token!).getUint32(0, Endian.little);
      expect(trimCursor, 113405);
    });
  });

  group('gen5 COMMAND_RESPONSE — battery scale + GET_HELLO', () {
    test('gen5 GET_BATTERY_LEVEL is direct-percent, not deci-percent', () {
      // inner = [0x24][seq][0x1A][echoed seq][status=1][47%] — gen5's
      // direct-percent form, body starting after the 5-byte response header.
      final inner = Uint8List(6);
      inner[0] = PacketType.commandResponse;
      inner[1] = 0;
      inner[2] = Cmd.getBatteryLevel;
      inner[3] = 7; // echoed request seq
      inner[4] = 1; // status: ok
      inner[5] = 47;
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded['battery_pct'], 47.0);
    });

    test('gen5 GET_BATTERY_LEVEL reports nothing when the strap says it failed',
        () {
      // On a fuel-gauge error the body is left untouched, so these bytes are
      // stale — a plausible-looking percentage that was never measured.
      final inner = Uint8List(6);
      inner[0] = PacketType.commandResponse;
      inner[2] = Cmd.getBatteryLevel;
      inner[3] = 7;
      inner[4] = 0; // status: failed
      inner[5] = 47;
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded.containsKey('battery_pct'), isFalse);
      expect(r.decoded['cmd_status'], 0);
    });

    test('the same bytes read as gen4 would misinterpret as deci-percent', () {
      final inner = Uint8List(7);
      inner[0] = PacketType.commandResponse;
      inner[2] = Cmd.getBatteryLevel;
      inner[5] = 10;
      inner[6] = 0; // u16 LE @5 = 10 → 1.0% under gen4's /10 scale
      final r4 = parseCommandResponse(inner)!;
      expect(r4.decoded['battery_pct'], 1.0);
    });

    // Build a gen5 GET_HELLO reply body per the revision-1 fixed map, with
    // synthetic identity values. Returns the 104-byte body (offsets are
    // body-relative).
    Uint8List gen5HelloBody() {
      final body = Uint8List(Gen5HelloInfo.semanticBodyLen);
      final bd = ByteData.sublistView(body);
      body[0] = 1; // hello revision
      bd.setUint32(1, 901, Endian.little); // battery raw 901 → 90
      body[5] = 0; // not charging
      bd.setUint32(6, 1780000000, Endian.little); // ts seconds
      bd.setUint32(10, 28835, Endian.little); // ts subseconds
      for (var i = 0; i < '5AG0000001'.length; i++) {
        body[14 + i] = '5AG0000001'.codeUnitAt(i); // serial (NUL-padded)
      }
      // commit (24B) / cpu (30B): fill with recognizable bytes.
      for (var i = 25; i < 49; i++) {
        body[i] = 0xAB;
      }
      for (var i = 49; i < 79; i++) {
        body[i] = 0xCD;
      }
      bd.setUint32(79, 13, Endian.little); // hardware family
      bd.setUint32(83, 0, Endian.little); // pcba revision
      bd.setUint32(87, 82, Endian.little); // optical discriminator → WHOOP 5
      body[91] = 50; // fw major
      body[92] = 40; // fw minor
      body[93] = 1; // fw build
      bd.setUint32(94, 0, Endian.little); // fw unreleased
      body[98] = 11; // sigproc major
      body[99] = 1; // sigproc minor
      body[100] = 0; // sigproc patch
      body[101] = 0; // hr broadcast
      body[102] = 1; // on-body
      body[103] = 0; // error byte
      return body;
    }

    test('Gen5HelloInfo.parse decodes the revision-1 body map', () {
      final h = Gen5HelloInfo.parse(gen5HelloBody())!;
      expect(h.helloRevision, 1);
      expect(h.batteryPct, 90); // 901 ~/ 10
      expect(h.charging, isFalse);
      expect(h.tsSeconds, 1780000000);
      expect(h.tsSubseconds, 28835);
      expect(h.serial, '5AG0000001');
      expect(h.hardwareFamily, 13);
      expect(h.opticalDiscriminator, 82);
      expect(h.isWhoop5, isTrue);
      expect(h.firmwareVersion, '50.40.1.0');
      expect(h.signalProcessorVersion, '11.1.0');
      expect(h.wristOn, isTrue);
      expect(h.commitHex.length, 48); // 24 bytes → 48 hex chars
      expect(h.cpuHex.length, 60); // 30 bytes → 60 hex chars
    });

    test('gen5 GET_HELLO surfaces Gen5HelloInfo through the full inner packet',
        () {
      // Integration vector: a COMPLETE command-response inner packet, not just
      // a body — proves parseCommandResponse hands the branch the body at the
      // right offset (past the 5-byte header). An off-by-two here would fail.
      final body = gen5HelloBody();
      final inner = Uint8List(5 + body.length);
      inner[0] = PacketType.commandResponse;
      inner[1] = 9; // response packet seq
      inner[2] = Cmd.getHello; // echoed opcode
      inner[3] = 7; // echoed request seq
      inner[4] = 1; // status: SUCCESS
      inner.setRange(5, 5 + body.length, body);
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded['req_seq'], 7);
      expect(r.decoded['cmd_status'], 1);
      final h = r.decoded['gen5_hello'] as Gen5HelloInfo;
      expect(h.serial, '5AG0000001');
      expect(h.firmwareVersion, '50.40.1.0');
      expect(h.wristOn, isTrue);
      // `device_name` is gone for good: it read the CPU/signature field, so it
      // was a wrong value, not a moved one.
      expect(r.decoded.containsKey('device_name'), isFalse);
      // `fw_version` is KEPT as a compat alias for one release — the old decode
      // happened to read the true major/minor/build bytes, so silently
      // returning null to existing callers would break a working field.
      expect(r.decoded['fw_version'], Uint8List.fromList([50, 40, 1, 0]));
    });

    test('a non-SUCCESS reply publishes no hello (stale-body guard)', () {
      // Hello answers PENDING first, and FAILURE/UNSUPPORTED are real
      // terminal cases. A non-success body is not populated, so parsing it
      // would mint a serial/battery/firmware out of whatever the buffer held.
      for (final status in [0, 2, 3]) {
        final body = gen5HelloBody();
        final inner = Uint8List(5 + body.length);
        inner[0] = PacketType.commandResponse;
        inner[2] = Cmd.getHello;
        inner[3] = 7;
        inner[4] = status;
        inner.setRange(5, 5 + body.length, body);
        final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
        expect(r.decoded.containsKey('gen5_hello'), isFalse,
            reason: 'status $status must not publish a hello');
      }
    });

    test('a non-1 hello revision still parses at the fixed offsets', () {
      // The revision byte is recorded, not a gate — the official parser reads
      // the fixed offsets regardless of its value.
      final body = gen5HelloBody();
      body[0] = 2; // some future revision
      final h = Gen5HelloInfo.parse(body)!;
      expect(h.helloRevision, 2);
      expect(h.batteryPct, 90);
      expect(h.serial, '5AG0000001');
      expect(h.firmwareVersion, '50.40.1.0');
      expect(h.wristOn, isTrue);
    });

    test('an out-of-range battery is omitted, never clamped', () {
      final body = gen5HelloBody();
      ByteData.sublistView(body).setUint32(1, 99999, Endian.little); // 9999%
      final h = Gen5HelloInfo.parse(body)!;
      expect(h.batteryPct, isNull);
      expect(h.serial, '5AG0000001'); // the rest of the record still decodes
    });

    test('gen5 GET_HELLO omits the hello when the body is too short', () {
      final inner = Uint8List(5 + 80); // < 104-byte semantic body
      inner[0] = PacketType.commandResponse;
      inner[2] = Cmd.getHello;
      inner[3] = 7;
      inner[4] = 1;
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded.containsKey('gen5_hello'), isFalse);
    });
  });

  group('CONSOLE_LOGS (0x32) decoder', () {
    // A 0x32 packet carries the EVENT envelope with event id 2: the seq is a
    // u8 at [1], the id a u16 at [2], and the text starts at [12] — there is
    // no channel byte. This builder used to write a u16 record_index over the
    // seq+id field and a fake channel at [12], which matched the decoder's own
    // (wrong) offsets.
    Uint8List buildConsoleLog(int recordIndex, int unix, String text) {
      final textBytes = text.codeUnits;
      final inner = Uint8List(12 + textBytes.length);
      inner[0] = PacketType.consoleLogs;
      inner[1] = recordIndex;
      ByteData.sublistView(inner).setUint16(2, 2, Endian.little); // event id
      ByteData.sublistView(inner).setUint32(4, unix, Endian.little);
      ByteData.sublistView(inner).setUint16(8, 0, Endian.little); // subsec
      ByteData.sublistView(inner)
          .setUint16(10, textBytes.length, Endian.little); // chunk_len
      inner.setRange(12, 12 + textBytes.length, textBytes);
      return inner;
    }

    test('decodes record_index/unix/text', () {
      final inner = buildConsoleLog(100, 1780000000,
          '146552119: BLE_CMD: Command Send Historical Data\n');
      final c = parseConsoleLog(inner)!;
      expect(c.recordIndex, 100);
      expect(c.unix, 1780000000);
      expect(c.text, '146552119: BLE_CMD: Command Send Historical Data\n');
    });

    test('trims only a TRAILING NUL run, preserving embedded NULs', () {
      final inner = buildConsoleLog(1, 1, 'ab\x00cd\x00\x00\x00');
      final c = parseConsoleLog(inner)!;
      expect(c.text, 'ab\x00cd'); // trailing NULs gone, embedded one kept
    });

    test(
        'ConsoleLogReassembler joins contiguous record_index chunks and flushes on a gap',
        () {
      final r = ConsoleLogReassembler();
      expect(r.add(parseConsoleLog(buildConsoleLog(1, 1, 'hello '))!),
          isFalse); // first chunk
      expect(r.add(parseConsoleLog(buildConsoleLog(2, 1, 'world'))!),
          isTrue); // contiguous
      expect(r.flush(), 'hello world');
      // A gap (index jumps from 2 to 2 again, i.e. non-contiguous) starts a
      // fresh run rather than splicing.
      expect(r.add(parseConsoleLog(buildConsoleLog(2, 1, 'x'))!), isFalse);
      expect(r.add(parseConsoleLog(buildConsoleLog(3, 1, 'y'))!), isTrue);
      expect(r.flush(), 'xy');
    });
  });

  group('decodeFrame dispatch — gen5 historical routing', () {
    test('a gen5 v18 frame dispatches to gen5_historical via BandProfile.gen5',
        () {
      final frame = hex(
        'aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000'
        '000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000'
        '000000000000f7000901f10b0007010c020c000000000000000000000000000'
        '00000000000000000000100656f1e1e0000009d61a7c00000003e862817',
      );
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      final d = decodeFrame(parsed, profile: BandProfile.gen5);
      expect(d.kind, 'gen5_historical');
      expect(d.fields['hist_version'], 18);
      expect(d.fields['ts_epoch'], 1780916150);
    });

    // Battery-pack ("puffin") wrapper types must decode to a NAMED kind, never
    // 'other' — 53/54/55 are history-count members a client has to
    // count and retain; 37/38/56 are named so nothing silently drops them.
    Uint8List wrapperFrame(int packetType) {
      // A minimal aligned inner packet whose first byte is the packet type.
      final inner = Uint8List.fromList([packetType, 0x01, 0x00, 0x00]);
      return buildFrame(inner, profile: BandProfile.gen5);
    }

    for (final t in [
      PacketType.relativePuffinEvents,
      PacketType.puffinEventsFromStrap,
      PacketType.relativeBatteryPackConsoleLogs,
    ]) {
      test('battery-pack wrapper type $t decodes to puffin_event (count member)',
          () {
        final parsed = parseFrame(wrapperFrame(t), profile: BandProfile.gen5)!;
        final d = decodeFrame(parsed, profile: BandProfile.gen5);
        expect(d.kind, 'puffin_event');
        expect(d.fields['packet_type'], t);
        expect(d.fields['retain_raw'], isTrue);
      });
    }

    for (final t in [
      PacketType.puffinCommand,
      PacketType.puffinCommandResponse,
      PacketType.puffinMetadata,
    ]) {
      test('battery-pack type $t decodes to a named kind, not other', () {
        final parsed = parseFrame(wrapperFrame(t), profile: BandProfile.gen5)!;
        final d = decodeFrame(parsed, profile: BandProfile.gen5);
        expect(d.kind, 'puffin');
        expect(d.fields['packet_type'], t);
      });
    }
  });
}
