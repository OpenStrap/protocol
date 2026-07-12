import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WHOOP command builders', () {
    test('history result success uses cmd 0x17 + success byte + token', () {
      final frame = parseFrame(
        buildHistoryResultOk(0x21, hexToBytes('1122334455667788')),
      )!;
      expect(frame.valid, isTrue);
      expect(
        frame.inner,
        [0x23, 0x21, 0x17, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
      );
    });

    test('history result failure uses cmd 0x17 + failure byte', () {
      final frame = parseFrame(buildHistoryResultFail(0x22))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [0x23, 0x22, 0x17, 0x00]);
    });

    test('enter high-frequency sync uses revision 2 + little-endian u16s', () {
      final frame = parseFrame(
        cmdEnterHighFreqSync(0x12, intervalSeconds: 300, durationSeconds: 900),
      )!;
      expect(frame.valid, isTrue);
      expect(
        frame.inner,
        [0x23, 0x12, 0x60, 0x02, 0x2c, 0x01, 0x84, 0x03],
      );
    });

    test('exit high-frequency sync is payloadless', () {
      final frame = parseFrame(cmdExitHighFreqSync(0x34))!;
      expect(frame.valid, isTrue);
      expect(frame.inner.sublist(0, 3), [0x23, 0x34, 0x61]);
    });

    test('select wrist writes revision 1 + laterality', () {
      final frame = parseFrame(cmdSelectWrist(0x07, WristSelection.left))!;
      expect(frame.valid, isTrue);
      expect(frame.inner.sublist(0, 5), [0x23, 0x07, 0x7b, 0x01, 0x02]);
    });

    test('modern hello uses opcode 0x91 with revision 1 payload', () {
      final frame = parseFrame(cmdGetHelloModern(0x01))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [0x23, 0x01, 0x91, 0x01]);
    });

    // Export reachability: these are resolved via the public
    // package:openstrap_protocol/openstrap_protocol.dart import above.
    test('cmdGetClock is exported and payloadless (opcode 0x0B)', () {
      final frame = parseFrame(cmdGetClock(0x05))!;
      expect(frame.valid, isTrue);
      // 3-byte inner + 1 byte of /4 frame padding.
      expect(frame.inner, [0x23, 0x05, 0x0B, 0x00]);
    });

    test('cmdGetDataRange is exported with a [0x00] payload (opcode 0x22)', () {
      final frame = parseFrame(cmdGetDataRange(0x06))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [0x23, 0x06, 0x22, 0x00]);
    });

    test('cmdSetClock builds the WHOOP-exact 8-byte sec+subsec payload', () {
      // Fixed instant: sec = 0x12345678, millis = 500.
      // subsec = 500 * 32768 ~/ 1000 = 16384 = 0x4000 (u16 LE, then 2 zero pad).
      final now =
          DateTime.fromMillisecondsSinceEpoch(0x12345678 * 1000 + 500);
      final frame = parseFrame(cmdSetClock(0x09, now: now))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [
        0x23, 0x09, Cmd.setClock, // header: COMMAND, seq, SET_CLOCK 0x0A
        0x78, 0x56, 0x34, 0x12, // seconds u32 LE
        0x00, 0x40, // subsec u16 LE (16384/32768 = 0.5 s)
        0x00, 0x00, // zero pad — total payload exactly 8 bytes
        0x00, // 1 byte of /4 frame padding (11-byte inner → 12)
      ]);
    });

    test('cmdSetClock subsec stays in u16 range at 999 ms', () {
      // subsec = 999 * 32768 ~/ 1000 = 32735 = 0x7FDF — never overflows u16.
      final now = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000 + 999);
      final frame = parseFrame(cmdSetClock(0x00, now: now))!;
      expect(frame.valid, isTrue);
      // header(3) + 8-byte payload = 11, padded /4 → 12 on the wire.
      expect(frame.inner.length, 12);
      expect(frame.inner.sublist(7, 11), [0xDF, 0x7F, 0x00, 0x00]);
    });
  });

  group('WHOOP danger surface', () {
    test('dangerousCmds covers trim, reboot, power-cycle, R21 and fw-load', () {
      expect(
        dangerousCmds,
        containsAll([
          Cmd.forceTrim,
          Cmd.rebootStrap,
          Cmd.powerCycleStrap,
          Cmd.togglePersistentR21,
          Cmd.startFirmwareLoad,
          Cmd.loadFirmwareData,
          Cmd.processFirmwareImage,
        ]),
      );
      // 0x24 here is a Cmd opcode; PacketType.commandResponse (0x24) is a
      // separate namespace (inner[0], not inner[2]).
      expect(Cmd.startFirmwareLoad, 0x24);
      expect(Cmd.powerCycleStrap, 0x20);
      // 0x62 is GET_EXTENDED_BATTERY_INFO; there is no 0x63 command (the old
      // "reset fuel gauge" opcode was a decode artifact and has been removed).
      expect(Cmd.getExtendedBatteryInfo, 0x62);
      expect(Cmd.getMaxProtocolVersion, 0x02);
    });
  });

  group('WHOOP command response decode', () {
    test('0x54 body location/status decodes exact fields', () {
      final inner = hexToBytes('2401540107a005');
      final resp = parseCommandResponse(inner)!;
      final body =
          resp.decoded['body_location_status'] as BodyLocationStatusResponse;
      expect(resp.opcode, Cmd.getBodyLocationAndStatus);
      expect(body.revision, 1);
      expect(body.locationRaw, 7);
      expect(body.location, GarmentDeviceLocation.ankle);
      expect(body.confidence, 160);
      expect(body.status, 5);
    });

    test('0x97 battery pack info decodes identifier, name and type', () {
      final inner = hexToBytes(
        '240297'
        '0101'
        '112233445566'
        '50756666696e20426174746572790000'
        '0000'
        '0c'
        '07',
      );
      final resp = parseCommandResponse(inner)!;
      final pack = resp.decoded['battery_pack_info'] as BatteryPackInfoResponse;
      expect(resp.opcode, Cmd.getBatteryPackInfo);
      expect(pack.revision, 1);
      expect(pack.attached, isTrue);
      expect(pack.identifier, '11:22:33:44:55:66');
      expect(pack.name, 'Puffin Battery');
      expect(pack.batteryPackTypeRaw, 12);
      expect(pack.batteryPackType, BatteryPackType.puffin);
      expect(pack.statusRaw, 7);
    });

    test('0x07 version info is surfaced honestly as raw payload', () {
      final inner = hexToBytes('24010700112233445566778899aabbccddeeff0011');
      final resp = parseCommandResponse(inner)!;
      final info = resp.decoded['version_info'] as Map<String, dynamic>;
      expect(resp.opcode, Cmd.reportVersionInfo);
      expect(info['payload_len'], 18);
      expect(info['raw_hex'], '00112233445566778899aabbccddeeff0011');
    });

    test('0x7b select wrist response is modeled as an ack payload', () {
      final inner = hexToBytes('24037b0102');
      final resp = parseCommandResponse(inner)!;
      final ack = resp.decoded['select_wrist'] as SelectWristResponse;
      expect(resp.opcode, Cmd.selectWrist);
      expect(ack.revision, 1);
      expect(ack.payload, [0x01, 0x02]);
    });
  });

  group('WHOOP realtime HR revision 2', () {
    test('body location and off-body state decode from realtime HR v2', () {
      final body = hexToBytes(
        '0002'
        '78563412'
        'bc9a'
        '4f'
        '000000000000000000'
        '00'
        '02',
      );
      final parsed = parseRealtimeHrV2(body)!;
      expect(parsed.revision, 2);
      expect(parsed.tsEpoch, 0x12345678);
      expect(parsed.tsSubsecRaw, 0x9abc);
      expect(parsed.hrBpm, 0x4f);
      expect(parsed.isOffBody, isTrue);
      expect(parsed.locationRaw, 2);
      expect(parsed.location, GarmentDeviceLocation.bicep);
    });
  });

  group('WHOOP on-device alarm', () {
    // Fixed instant: sec = 0x12345678, millis = 500.
    // subsec = 500 * 32768 ~/ 1000 = 16384 = 0x4000 (u16 LE).
    final when = DateTime.fromMillisecondsSinceEpoch(0x12345678 * 1000 + 500);

    test('simple form is [0x01][u32 sec LE][u16 subsec LE]', () {
      final frame = parseFrame(cmdSetAlarmSimple(0x0A, when))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [
        0x23, 0x0A, Cmd.setAlarmTime, // COMMAND, seq, SET_ALARM_TIME 0x42
        0x01, //                         time-only form marker
        0x78, 0x56, 0x34, 0x12, //       epoch seconds u32 LE
        0x00, 0x40, //                   sub-seconds u16 LE (16384 = 0.5 s)
        0x00, 0x00, //                   /4 frame padding (10-byte inner → 12)
      ]);
    });

    test('rich form carries the default 12-byte haptic pattern and fires', () {
      final frame = parseFrame(cmdSetAlarm(0x0B, when))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [
        0x23, 0x0B, Cmd.setAlarmTime, // COMMAND, seq, SET_ALARM_TIME 0x42
        0x04, //                         rich-form marker (fires haptics)
        0x00, //                         alarm slot index (default 0)
        0x78, 0x56, 0x34, 0x12, //       epoch seconds u32 LE
        0x00, 0x40, //                   sub-seconds u16 LE
        47, 152, 0, 0, 0, 0, 0, 0, //    8× waveform effects
        0, 0, //                         loopControl u16 LE
        7, //                            overall waveform loop
        30, //                           duration seconds
        0x00, //                         /4 frame padding (23-byte inner → 24)
      ]);
      // The default pattern exported for callers matches what we serialise.
      expect(kDefaultAlarmHaptics,
          [47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30]);
    });

    test('rich form honours a custom index and haptic pattern', () {
      final custom = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
      final frame =
          parseFrame(cmdSetAlarm(0x00, when, index: 3, hapticPattern: custom))!;
      expect(frame.inner.sublist(3, 11),
          [0x04, 0x03, 0x78, 0x56, 0x34, 0x12, 0x00, 0x40]);
      expect(frame.inner.sublist(11, 23), custom);
    });

    test('rich form rejects a wrong-length haptic pattern', () {
      expect(() => cmdSetAlarm(0x00, when, hapticPattern: const [1, 2, 3]),
          throwsArgumentError);
    });

    test('run alarm rev1 is [0x01], rev2 is [0x02][mode] (opcode 0x44)', () {
      final rev1 = parseFrame(cmdRunAlarm(0x01))!;
      expect(rev1.inner, [0x23, 0x01, Cmd.runAlarm, 0x01]);
      final rev2 = parseFrame(cmdRunAlarm(0x02, mode: 0x05))!;
      expect(rev2.inner.sublist(0, 5), [0x23, 0x02, Cmd.runAlarm, 0x02, 0x05]);
    });

    test('disable alarm rev1 is [0x01], rev2 is [0x02][0xFF] (opcode 0x45)', () {
      final rev1 = parseFrame(cmdDisableAlarm(0x03))!;
      expect(rev1.inner, [0x23, 0x03, Cmd.disableAlarm, 0x01]);
      final rev2 = parseFrame(cmdDisableAlarm(0x04, revision: 2))!;
      expect(
          rev2.inner.sublist(0, 5), [0x23, 0x04, Cmd.disableAlarm, 0x02, 0xFF]);
    });
  });

  group('WHOOP event ids', () {
    test('newly confirmed ids resolve to their names', () {
      expect(EventId.boot, 15);
      expect(EventId.setRtc, 16);
      expect(EventId.hapticsFired, 60);
      expect(EventId.name(EventId.boot), 'BOOT');
      expect(EventId.name(EventId.setRtc), 'SET_RTC');
      expect(EventId.name(EventId.temperatureLevel), 'TEMPERATURE_LEVEL');
      expect(EventId.name(EventId.trimAllData), 'TRIM_ALL_DATA');
      expect(EventId.name(EventId.trimAllDataEnded), 'TRIM_ALL_DATA_ENDED');
      expect(EventId.name(EventId.ch1Saturation), 'CH1_SATURATION_DETECTED');
      expect(EventId.name(EventId.ch2Saturation), 'CH2_SATURATION_DETECTED');
      expect(EventId.name(EventId.accelSaturation),
          'ACCELEROMETER_SATURATION_DETECTED');
      expect(EventId.name(EventId.rawDataCollectionOn), 'RAW_DATA_COLLECTION_ON');
      expect(
          EventId.name(EventId.rawDataCollectionOff), 'RAW_DATA_COLLECTION_OFF');
      expect(EventId.name(EventId.strapDrivenAlarmSet), 'STRAP_DRIVEN_ALARM_SET');
      expect(EventId.name(EventId.strapDrivenAlarmExecuted),
          'STRAP_DRIVEN_ALARM_EXECUTED');
      expect(EventId.name(EventId.appDrivenAlarmExecuted),
          'APP_DRIVEN_ALARM_EXECUTED');
      expect(EventId.name(EventId.strapDrivenAlarmDisabled),
          'STRAP_DRIVEN_ALARM_DISABLED');
    });

    test('parseEvent decodes id@2, ts@4, subsec@8 and body@12', () {
      // 0x30 EVENT: eid=16 (SET_RTC) @2, ts=0x12345678 @4, subsec=0x4000 @8,
      // pad @10..12, body [0xAA,0xBB] @12.
      final inner = Uint8List.fromList([
        0x30, 0x00, //             packet type EVENT, seq
        0x10, 0x00, //             event id u16 LE = 16
        0x78, 0x56, 0x34, 0x12, // ts seconds u32 LE
        0x00, 0x40, //             sub-seconds u16 LE
        0x00, 0x00, //             pad to the body offset
        0xAA, 0xBB, //             event body
      ]);
      final e = parseEvent(inner)!;
      expect(e.eventId, EventId.setRtc);
      expect(e.name, 'SET_RTC');
      expect(e.tsEpoch, 0x12345678);
      expect(e.tsSubsec, 0x4000);
      expect(e.body, [0xAA, 0xBB]);
    });
  });

  group('WHOOP historical record versions', () {
    // Build a 96-byte record inner with a plausible ~1 g gravity vector and a
    // given HR at [hrOffset].
    Uint8List record(int version, {required int hr, required int hrOffset,
        double gz = 1.0}) {
      final b = Uint8List(96);
      b[0] = 0x2f; // packet type (historical)
      b[1] = version;
      final bd = ByteData.sublistView(b);
      bd.setUint32(3, 0x0A0B0C0D, Endian.little); // counter
      bd.setUint32(7, 0x11223344, Endian.little); // ts seconds
      bd.setUint16(11, 0x0102, Endian.little); // subsec
      b[hrOffset] = hr;
      bd.setFloat32(36, 0.0, Endian.little); // gravity x
      bd.setFloat32(40, 0.0, Endian.little); // gravity y
      bd.setFloat32(44, gz, Endian.little); // gravity z
      return b;
    }

    test('v18 reads HR at offset 14', () {
      final r = parseR24(record(18, hr: 60, hrOffset: 14))!;
      expect(r.histVersion, 18);
      expect(r.hr, 60);
      expect(r.counter, 0x0A0B0C0D);
      expect(r.tsEpoch, 0x11223344);
      expect(r.tsSubsec, 0x0102);
    });

    test('v24 still reads HR at offset 17 (trusted, un-gated)', () {
      // HR=0 (off-wrist) still decodes on the trusted path — no plausibility gate.
      final r = parseR24(record(24, hr: 0, hrOffset: 17))!;
      expect(r.histVersion, 24);
      expect(r.hr, 0);
    });

    test('unknown version decodes via v24 map when physiologically plausible',
        () {
      final r = parseR24(record(200, hr: 72, hrOffset: 17))!;
      expect(r.histVersion, 200);
      expect(r.hr, 72);
    });

    test('best-effort decode is rejected when HR is implausible', () {
      // v18 with HR below the human floor → null (only HR offset is confirmed).
      expect(parseR24(record(18, hr: 5, hrOffset: 14)), isNull);
    });

    test('best-effort decode is rejected when gravity is implausible', () {
      // Unknown version with near-zero gravity magnitude → null.
      expect(parseR24(record(200, hr: 72, hrOffset: 17, gz: 0.05)), isNull);
    });

    // Regression: a real device (user export, 2026-07) sent 11k+ consecutive
    // v12 records that were all exactly 88 bytes — one under parseR24's
    // 89-byte floor — and every one was silently archived as
    // "undecodable_rec_v12". That's a total sync outage for that user, not a
    // cosmetic gap. Fix: parseR24 itself stays exactly as validated (never
    // loosened); FirmwareAwareR24Decoder tries it first, then a 72-byte
    // fallback layout, before giving up.
    test('bare parseR24 still rejects an 88-byte v12 record (unchanged)', () {
      final full = record(12, hr: 65, hrOffset: 17);
      final short88 = Uint8List.sublistView(full, 0, 88);
      expect(parseR24(short88), isNull);
    });

    test(
        'FirmwareAwareR24Decoder recovers the 88-byte v12 record via the '
        'fallback chain', () {
      final full = record(12, hr: 65, hrOffset: 17);
      final short88 = Uint8List.sublistView(full, 0, 88);
      final decoder = FirmwareAwareR24Decoder();
      final r = decoder.decode(short88)!;
      expect(r.histVersion, 12);
      expect(r.hr, 65);
      expect(r.counter, 0x0A0B0C0D);
      expect(r.tsEpoch, 0x11223344);
      expect(decoder.detectedStrategies[12], 'short_frame_72b');
    });

    test(
        'FirmwareAwareR24Decoder decodes the exact real-world 88-byte v12 '
        'record (raw capture)', () {
      // Captured verbatim from a user's raw_archive export.
      final r = FirmwareAwareR24Decoder().decode(hexToBytes(
        '2f0c05ab7c4a019e814e6a300180644001560000000000000000000060c803'
        'f2a08df23c5c4b033f29d84b3f5c9f16be007c39c65c4b033f29d84b3f5c9f1'
        '6be41027b020a047b024601a006010ba2070000009052f20001',
      ))!;
      expect(r.histVersion, 12);
    });

    test(
        'FirmwareAwareR24Decoder still returns null below the 72-byte floor',
        () {
      final full = record(12, hr: 65, hrOffset: 17);
      final tooShort = Uint8List.sublistView(full, 0, 71);
      expect(FirmwareAwareR24Decoder().decode(tooShort), isNull);
    });

    test(
        'FirmwareAwareR24Decoder keeps v12 trusted/un-gated at the shorter '
        'length', () {
      // HR=0 (off-wrist) must still decode on the trusted path at 72 bytes —
      // the fallback layout must not accidentally start gating v12.
      final full = record(12, hr: 0, hrOffset: 17, gz: 0.0);
      final atMin = Uint8List.sublistView(full, 0, 72);
      final r = FirmwareAwareR24Decoder().decode(atMin)!;
      expect(r.histVersion, 12);
      expect(r.hr, 0);
    });

    test(
        'FirmwareAwareR24Decoder prefers the FIRST-detected strategy on '
        'later calls, but re-probes if it stops matching', () {
      final decoder = FirmwareAwareR24Decoder();
      final full89 = record(12, hr: 70, hrOffset: 17);
      final short88 = Uint8List.sublistView(record(12, hr: 71, hrOffset: 17), 0, 88);

      // First record is full-length → legacy strategy wins and is remembered.
      expect(decoder.decode(full89)!.hr, 70);
      expect(decoder.detectedStrategies[12], 'legacy_89b');

      // A later record from the same "detected" version that's actually
      // short must still decode by falling through, and detection updates.
      expect(decoder.decode(short88)!.hr, 71);
      expect(decoder.detectedStrategies[12], 'short_frame_72b');
    });

    test('FirmwareAwareR24Decoder detects independently per record version',
        () {
      final decoder = FirmwareAwareR24Decoder();
      final v12Short =
          Uint8List.sublistView(record(12, hr: 65, hrOffset: 17), 0, 88);
      final v24Full = record(24, hr: 80, hrOffset: 17);
      decoder.decode(v12Short);
      decoder.decode(v24Full);
      expect(decoder.detectedStrategies[12], 'short_frame_72b');
      expect(decoder.detectedStrategies[24], 'legacy_89b');
    });
  });

  group('WHOOP event decode', () {
    test('high-frequency prompt/enabled/disabled events are modeled', () {
      final prompt = parseEvent(hexToBytes('3001600001020304'))!;
      final enabled = parseEvent(hexToBytes('3001610001020304'))!;
      final disabled = parseEvent(hexToBytes('3001620001020304'))!;

      expect(prompt.eventId, EventId.highFreqSyncPrompt);
      expect(prompt.name, 'HIGH_FREQ_SYNC_PROMPT');
      expect(prompt.decoded['high_freq_sync'], 'prompt');

      expect(enabled.eventId, EventId.highFreqSyncEnabled);
      expect(enabled.name, 'HIGH_FREQ_SYNC_ENABLED');
      expect(enabled.decoded['high_freq_sync'], 'enabled');

      expect(disabled.eventId, EventId.highFreqSyncDisabled);
      expect(disabled.name, 'HIGH_FREQ_SYNC_DISABLED');
      expect(disabled.decoded['high_freq_sync'], 'disabled');
    });
  });

  group('WHOOP metadata decode', () {
    test('history end exposes expected packet count and ack token', () {
      final m = parseMetadata(
        hexToBytes('3100020000000000002a0000001122334455667788'),
      )!;
      expect(m.sub, SyncMeta.historyEnd);
      expect(m.expectedPacketCount, 42);
      expect(m.token, hexToBytes('1122334455667788'));
    });
  });

  group('compact 0x28 realtime HR decode', () {
    // used to read ts one byte early (off inner[3] instead of inner[2], left
    // over from a 3-byte header skip) and hr as a fake u16/256 value instead
    // of the plain byte it actually is - found this against a real capture
    // where it decoded to some year-2089 garbage timestamp.
    test('reads ts/hr/rr from the real layout, not shifted by the old header skip', () {
      final b = Uint8List(20);
      final bd = b.buffer.asByteData();
      b[0] = 0x28;
      bd.setUint32(2, 1780840486, Endian.little); // ts
      b[8] = 65; // hr
      b[9] = 1; // rr_count
      bd.setInt16(10, 900, Endian.little); // rr1
      b[18] = 1; // wearing

      final decoded = decodeFrame(Frame(b, true, true));
      expect(decoded.kind, 'realtime_hr');
      // copilot review flagged this - the whole point of the bug was
      // corrupted timestamps, and this test never actually checked one.
      expect(decoded.fields['ts_epoch'], 1780840486);
      expect(decoded.fields['hr'], 65);
      expect(decoded.fields['rr_ms'], [900]);
      expect(decoded.fields['wearing'], isTrue);
    });

    // copilot review also caught a real one: a 9-byte packet (ts+hr, no
    // rr_count byte at all) would read inner[9] out of bounds and throw
    // instead of decoding. fixed to treat a missing rr_count byte as "no RR
    // intervals" rather than crashing.
    test('a 9-byte packet (ts+hr only, no rr_count byte) decodes instead of throwing', () {
      final b = Uint8List(9);
      final bd = b.buffer.asByteData();
      b[0] = 0x28;
      bd.setUint32(2, 1780840486, Endian.little);
      b[8] = 65;

      final decoded = decodeFrame(Frame(b, true, true));
      expect(decoded.kind, 'realtime_hr');
      expect(decoded.fields['ts_epoch'], 1780840486);
      expect(decoded.fields['hr'], 65);
      expect(decoded.fields['rr_ms'], isEmpty);
    });
  });
}
