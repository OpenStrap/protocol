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

    test('quality flags + alt HR', () {
      expect(sample.hrQualityFlags, 0x8D);
      expect(sample.hrRrValidThisSecond, isTrue); // bit7 set
      expect(sample.heartRateAlt, 101);
      expect(sample.trustedHeartRateAlt, 101);
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
      expect(sample.activityClass, 0); // still
    });

    test('temperature (gen5-specific scales)', () {
      expect(sample.tempAux1C, closeTo(24.7, 1e-6));
      expect(sample.tempAux2C, closeTo(26.5, 1e-6));
      expect(sample.skinTempC, closeTo(30.57, 1e-6));
    });

    test('optical front-end', () {
      expect(sample.opticalBaselineA, 101);
      expect(sample.opticalBaselineB, 111);
      expect(sample.opticalAmpA, 30);
      expect(sample.opticalAmpB, 30);
      expect(sample.isOpticalAmpSentinel, isFalse); // not the 128/128 sentinel
    });

    test('experimental fields exposed raw, not fabricated', () {
      // cardiac_status / signal_quality (disputed offset semantics, §1.7):
      // raw byte only, no anomaly gate wired off it.
      expect(sample.cardiacStatusRaw, 255);
      // spo2_candidate gated 70..100 — this fixture's raw byte is 0, so the
      // gated getter must be null, never a fabricated "0%".
      expect(sample.spo2CandidateRaw, 0);
      expect(sample.spo2Candidate, isNull);
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

    test(
        'decodes record_index as u32 (NOT u16 — §1.7), unix, and the full 24-sample waveform',
        () {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue);
      final r = parseGen5Historical(parsed.inner);
      expect(r, isA<Gen5PpgWaveform>());
      final wf = r as Gen5PpgWaveform;
      expect(wf.histVersion, 26);
      expect(wf.recordIndex, 25444781); // u16 read would give 16813 — wrong
      expect(wf.unix, 1780917232);
      expect(wf.rawByte19, 174);
      expect(wf.burstIndex, 1);
      expect(wf.ppgWaveform, [
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
      ]);
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

    test('rejects a buffer whose counts are not both 100', () {
      final inner = buildV21(recordIndex: 1, unix: 1780000000);
      ByteData.sublistView(inner)
          .setUint16(622, 99, Endian.little); // countB wrong
      expect(parseGen5Historical(inner), isNull);
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
      // inner = [0x24][seq][0x1A][47%] — gen5's direct-percent form.
      final inner = Uint8List(6);
      inner[0] = PacketType.commandResponse;
      inner[1] = 0;
      inner[2] = Cmd.getBatteryLevel;
      inner[3] = 0;
      inner[4] = 0;
      inner[5] = 47;
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded['battery_pct'], 47.0);
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

    test('gen5 GET_HELLO (0x91) decodes device_name + gated fw_version', () {
      final inner = Uint8List(120);
      inner[0] = PacketType.commandResponse;
      inner[1] = 0;
      inner[2] = Cmd.getHello;
      final payload = Uint8List.sublistView(inner, 3);
      // device_name @ pay[16]
      final name = 'MyStrap';
      for (int i = 0; i < name.length; i++) {
        payload[16 + i] = name.codeUnitAt(i);
      }
      // fw_version @ pay[93:97], gated on pay[93]==50
      payload[93] = 50;
      payload[94] = 38;
      payload[95] = 1;
      payload[96] = 0;
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded['device_name'], 'MyStrap');
      expect(r.decoded['fw_version'], Uint8List.fromList([50, 38, 1, 0]));
    });

    test('gen5 GET_HELLO omits fw_version when the gate byte does not match',
        () {
      final inner = Uint8List(120);
      inner[0] = PacketType.commandResponse;
      inner[2] = Cmd.getHello;
      inner[3 + 93] = 99; // not 50
      final r = parseCommandResponse(inner, profile: BandProfile.gen5)!;
      expect(r.decoded.containsKey('fw_version'), isFalse);
    });
  });

  group('CONSOLE_LOGS (0x32) decoder', () {
    Uint8List buildConsoleLog(int recordIndex, int unix, String text) {
      final textBytes = text.codeUnits;
      final inner = Uint8List(13 + textBytes.length);
      inner[0] = PacketType.consoleLogs;
      ByteData.sublistView(inner).setUint16(1, recordIndex, Endian.little);
      ByteData.sublistView(inner).setUint32(4, unix, Endian.little);
      ByteData.sublistView(inner).setUint16(8, 0, Endian.little); // subsec
      ByteData.sublistView(inner)
          .setUint16(10, textBytes.length, Endian.little); // chunk_len
      inner[12] = 1; // channel
      inner.setRange(13, 13 + textBytes.length, textBytes);
      return inner;
    }

    test('decodes record_index/unix/channel/text', () {
      final inner = buildConsoleLog(100, 1780000000,
          '146552119: BLE_CMD: Command Send Historical Data\n');
      final c = parseConsoleLog(inner)!;
      expect(c.recordIndex, 100);
      expect(c.unix, 1780000000);
      expect(c.channel, 1);
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
  });
}
