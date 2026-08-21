// gen5 command-surface byte layouts.
//
// Every command a gen5 strap parses starts with a revision byte, and a body
// that is too short is read as revision 0 and rejected — silently, with no
// error the caller can see. These tests pin the byte layouts that used to be
// wrong: missing revision bytes, short config bodies, the inverted config
// values, and the alarm forms.
//
// Imports src/ directly (rather than the package's public library) so the
// builders that are not re-exported yet are still covered.

import 'dart:typed_data';

import 'package:openstrap_protocol/src/band.dart';
import 'package:openstrap_protocol/src/commands.dart';
import 'package:openstrap_protocol/src/constants.dart';
import 'package:openstrap_protocol/src/framing.dart';
import 'package:test/test.dart';

/// The command body (everything after `[type][seq][opcode]`), still carrying
/// whatever /4 padding the frame added.
Uint8List _body(Uint8List frame, {BandProfile profile = BandProfile.gen4}) {
  final f = parseFrame(frame, profile: profile)!;
  expect(f.valid, isTrue, reason: 'frame CRCs must be valid');
  return f.inner.sublist(3);
}

void main() {
  const gen5 = BandProfile.gen5;

  group('commands that used to send an empty body', () {
    test('GET_BODY_LOCATION_AND_STATUS (0x54) carries the revision byte', () {
      for (final p in [BandProfile.gen4, gen5]) {
        final f =
            parseFrame(cmdGetBodyLocationAndStatus(1, profile: p), profile: p)!;
        expect(f.opcode, 0x54);
        expect(f.inner[3], 0x01,
            reason: 'body[0] is the revision, not padding');
      }
    });

    test('GET_BATTERY_PACK_INFO (0x97) carries the revision byte', () {
      for (final p in [BandProfile.gen4, gen5]) {
        final f = parseFrame(cmdGetBatteryPackInfo(1, profile: p), profile: p)!;
        expect(f.opcode, 0x97);
        expect(f.inner[3], 0x01);
      }
    });
  });

  group('SET_CONFIG (120) / SET_DEVICE_CONFIG_VALUE (119) 65-byte body', () {
    // [0x01][name:32B NUL-padded][value:32B NUL-padded]
    void expectConfigBody(Uint8List frame, int opcode, String name, String v) {
      final f = parseFrame(frame, profile: gen5)!;
      expect(f.valid, isTrue);
      expect(f.opcode, opcode);
      // 3 header bytes + 65-byte body = 68, already a multiple of 4 (no pad).
      expect(f.inner.length, 68, reason: 'body must be 65 bytes');
      expect(f.inner[3], 0x01, reason: 'revision byte');
      final nameField = f.inner.sublist(4, 36);
      expect(String.fromCharCodes(nameField.takeWhile((b) => b != 0)), name);
      final valueField = f.inner.sublist(36, 68);
      expect(valueField[0], v.codeUnitAt(0));
      expect(valueField.sublist(1), Uint8List(31),
          reason: 'value field is 32 bytes, NUL-padded');
    }

    test('SET_CONFIG body is 65 bytes with both fields 32 bytes wide', () {
      expectConfigBody(cmdSetConfigGen5(1, 'enable_r22_packets', '1'), 120,
          'enable_r22_packets', '1');
    });

    test('SET_DEVICE_CONFIG_VALUE has the same 65-byte body + revision', () {
      expectConfigBody(cmdSetDeviceConfigValueGen5(2, 'some_key', '0'), 119,
          'some_key', '0');
    });

    test('rejects an over-long name and a multi-char value', () {
      expect(() => cmdSetConfigGen5(1, 'x' * 32, '1'), throwsArgumentError);
      expect(() => cmdSetConfigGen5(1, 'ok', '12'), throwsArgumentError);
      expect(() => cmdSetDeviceConfigValueGen5(1, 'x' * 32, '1'),
          throwsArgumentError);
    });
  });

  group('R22 enable flags (persistent NVM writes)', () {
    test('every value is one of the three the firmware accepts', () {
      for (final (name, value) in kGen5R22EnableFlags) {
        expect(['0', '1', '2'], contains(value), reason: name);
      }
    });

    test('enable_* flags send "1" (enable), never "2" (disable)', () {
      for (final (name, value) in kGen5R22EnableFlags) {
        if (name.startsWith('enable_')) {
          expect(value, '1', reason: '$name must be enabled, not disabled');
        }
      }
    });

    test('the firmware-selected r22 packet flags (v6..v2 + master) are enabled',
        () {
      final enabled = {
        for (final (n, v) in kGen5R22EnableFlags)
          if (v == '1') n
      };
      expect(
          enabled,
          containsAll(<String>[
            'enable_r22_packets',
            'enable_r22_v2_packets',
            'enable_r22_v3_packets',
            'enable_r22_v5_packets',
            'enable_r22_v6_packets',
          ]));
    });

    test('the default sequence stays the full hardware-proven set', () {
      // The full set is the one with deep-buffer evidence behind it; trimming
      // it is the caller's explicit choice, never a silent change.
      final names = kGen5R22EnableFlags.map((f) => f.$1).toList();
      expect(names, contains('enable_r22_v4_packets'));
      expect(names, contains('enable_r22_v8_packets'));
    });

    test('the contested pair is named, and omitContestedFlags skips exactly it',
        () {
      // v4 reads raw 0 pre-write (no proven restoration — one-way); v8 has no
      // active firmware consumer. Both stay in the default; a caller that
      // refuses the irreversible/dormant writes opts out explicitly.
      expect(kGen5R22ContestedFlagNames,
          {'enable_r22_v4_packets', 'enable_r22_v8_packets'});
      final frames =
          buildR22EnableSequence(startSeq: 3, omitContestedFlags: true);
      expect(frames.length, kGen5R22EnableFlags.length - 2);
      final written = frames.map((fr) {
        final inner = parseFrame(fr, profile: gen5)!.inner;
        return String.fromCharCodes(
            inner.sublist(4, 36).takeWhile((b) => b != 0));
      }).toSet();
      expect(written.intersection(kGen5R22ContestedFlagNames), isEmpty);
      expect(written, contains('enable_r22_packets'));
      expect(written, contains('disable_pip_r26_packets'));
    });

    test('the pip suppressor is disabled so v26 packets flow', () {
      expect(kGen5R22EnableFlags, contains(('disable_pip_r26_packets', '2')));
    });

    test('touches nothing outside the deep buffers, and not enable_sig12', () {
      final names = kGen5R22EnableFlags.map((f) => f.$1).toList();
      // These change the strap's own HR / wear detection and must not be
      // written by an opt-in that only asks for deep buffers.
      expect(names, isNot(contains('hr_ch_switching')));
      expect(names, isNot(contains('wear_detect_bias')));
      expect(names, isNot(contains('ir_hw_switching')));
      expect(names, isNot(contains('enable_sig11_during_sleep')));
      expect(names, isNot(contains('dorset_inhibit_wpt')));
      // Not a setting this firmware has.
      expect(names, isNot(contains('enable_sig12')));
      expect(names.toSet().length, names.length, reason: 'no duplicate names');
    });

    test('enable sequence is one SET_CONFIG frame per flag, sequential seq',
        () {
      final frames = buildR22EnableSequence(startSeq: 3);
      expect(frames.length, kGen5R22EnableFlags.length);
      for (var i = 0; i < frames.length; i++) {
        final f = parseFrame(frames[i], profile: gen5)!;
        expect(f.valid, isTrue);
        expect(f.opcode, 120);
        expect(f.inner[1], 3 + i);
        expect(f.inner[36], kGen5R22EnableFlags[i].$2.codeUnitAt(0));
      }
    });

    test('the deprecated restore builder writes raw "0" — which is NOT a valid '
        'restore, and is why it is unexported', () {
      // Pinned as a HAZARD, not as correct behaviour. The boolean writer
      // emits only ASCII '1' (enabled) or '2' (disabled); a returned raw 0
      // means unset/unknown and is never a valid write value. So
      // this builder cannot restore anything — a correct restore reads each
      // flag first and writes the recorded value back.
      // ignore: deprecated_member_use_from_same_package
      final restore = buildR22RestoreDefaultsSequence(startSeq: 1);
      expect(restore.length, kGen5R22EnableFlags.length);
      for (var i = 0; i < restore.length; i++) {
        final inner = parseFrame(restore[i], profile: gen5)!.inner;
        final name =
            String.fromCharCodes(inner.sublist(4, 36).takeWhile((b) => b != 0));
        expect(name, kGen5R22EnableFlags[i].$1);
        expect(inner[36], '0'.codeUnitAt(0),
            reason: 'documents the unsafe raw-0 write this builder emits');
      }
    });

  });

  group('alarms', () {
    final when = DateTime.fromMillisecondsSinceEpoch(0x12345678 * 1000);

    test('gen4 keeps the hardware-verified 12-byte haptic block (20-byte body)',
        () {
      final body = _body(cmdSetAlarm(1, when));
      // [0x04][index][u32 sec][u16 subsec][12 haptic] = 20, padded to 21.
      expect(body.length, 21, reason: '20-byte body + one /4 pad byte');
      expect(body[0], 0x04);
      expect(body.sublist(8, 20), kDefaultAlarmHaptics);
    });

    test('gen5 sends a 13-byte haptic block: the 13th byte is the crescendo',
        () {
      final body = _body(cmdSetAlarm(1, when, crescendo: 1, profile: gen5),
          profile: gen5);
      expect(body.length, 21, reason: '21-byte body, already /4-aligned');
      expect(body.sublist(8, 20), kDefaultAlarmHaptics);
      expect(body[20], 1, reason: 'crescendo flag');
      final off = _body(cmdSetAlarm(1, when, profile: gen5), profile: gen5);
      expect(off[20], 0, reason: 'crescendo defaults to off');
    });

    test('crescendo must be 0 or 1', () {
      expect(() => cmdSetAlarm(1, when, crescendo: 2, profile: gen5),
          throwsArgumentError);
      expect(() => cmdSetAlarm(1, when, crescendo: -1, profile: gen5),
          throwsArgumentError);
    });

    test('gen5 alarm ids are 1..6 and slot 0 is rejected', () {
      expect(() => cmdSetAlarm(1, when, index: 0, profile: gen5),
          throwsArgumentError);
      expect(() => cmdSetAlarm(1, when, index: 7, profile: gen5),
          throwsArgumentError);
      for (var id = 1; id <= 6; id++) {
        expect(
            _body(cmdSetAlarm(1, when, index: id, profile: gen5),
                profile: gen5)[1],
            id);
      }
      // gen5's default lands on a slot RUN/DISABLE can actually address.
      expect(_body(cmdSetAlarm(1, when, profile: gen5), profile: gen5)[1], 1);
    });

    test('gen4 keeps slot 0 — it is the slot a WHOOP 4 fires from', () {
      // Verified on hardware. gen5's 1..6 rule must not be applied here: it
      // would reject the only alarm path we have seen actually work.
      expect(_body(cmdSetAlarm(1, when, index: 0))[1], 0);
      expect(_body(cmdSetAlarm(1, when))[1], 0);
      expect(() => cmdSetAlarm(1, when, index: 7), throwsArgumentError);
    });

    test('gen5 RUN_ALARM needs revision 2 plus an id', () {
      expect(() => cmdRunAlarm(1, profile: gen5), throwsArgumentError);
      expect(() => cmdRunAlarm(1, mode: 0, profile: gen5), throwsArgumentError);
      expect(() => cmdRunAlarm(1, mode: 7, profile: gen5), throwsArgumentError);
      final body = _body(cmdRunAlarm(1, mode: 3, profile: gen5), profile: gen5);
      expect(body.sublist(0, 2), [0x02, 0x03]);
    });

    test('a targeted cancel on the revision-1 body throws, never cancels all',
        () {
      // rev 1 has nowhere to put an id and cancels EVERY alarm. Dropping the
      // id silently would cancel all of them for a caller asking for one.
      expect(() => cmdDisableAlarm(1, alarmId: 3), throwsArgumentError);
      // Explicit rev 2 carries it, and omitting the id still means "all".
      expect(_body(cmdDisableAlarm(1, revision: 2, alarmId: 3))[0], 0x02);
      expect(_body(cmdDisableAlarm(1, revision: 2, alarmId: 3))[1], 3);
      expect(_body(cmdDisableAlarm(1))[0], 0x01);
    });

    test('gen5 DISABLE_ALARM is rev 2: 0xFF for all, or one id', () {
      final all = _body(cmdDisableAlarm(1, profile: gen5), profile: gen5);
      expect(all.sublist(0, 2), [0x02, 0xFF]);
      final one =
          _body(cmdDisableAlarm(1, alarmId: 4, profile: gen5), profile: gen5);
      expect(one.sublist(0, 2), [0x02, 0x04]);
      expect(() => cmdDisableAlarm(1, alarmId: 0, profile: gen5),
          throwsArgumentError);
      // gen4 default stays on revision 1.
      expect(_body(cmdDisableAlarm(1))[0], 0x01);
    });

    test('GET_ALARM_TIME is [0x01] on gen4 and [0x04][id] on gen5', () {
      expect(_body(cmdGetAlarmTime(1))[0], 0x01);
      // gen5 checks body[0] as a REVISION and must see 4, then reads the id
      // from body[1]. A bare id is rejected as an unsupported revision.
      final g5 =
          _body(cmdGetAlarmTime(1, alarmId: 3, profile: gen5), profile: gen5);
      expect(g5.sublist(0, 2), [0x04, 3]);
      expect(_body(cmdGetAlarmTime(1, profile: gen5), profile: gen5).sublist(0, 2),
          [0x04, 1]);
      expect(() => cmdGetAlarmTime(1, alarmId: 0, profile: gen5),
          throwsArgumentError);
    });
  });

  group('newly built gen5 commands', () {
    test('gyro enable (0x96) / status (0x98)', () {
      final on =
          parseFrame(cmdGyroEnable(1, true, profile: gen5), profile: gen5)!;
      expect(on.opcode, 0x96);
      expect(on.inner.sublist(3, 5), [0x01, 0x01]);
      final off =
          parseFrame(cmdGyroEnable(1, false, profile: gen5), profile: gen5)!;
      expect(off.inner.sublist(3, 5), [0x01, 0x00]);
      final status =
          parseFrame(cmdGyroStatus(1, profile: gen5), profile: gen5)!;
      expect(status.opcode, 0x98);
      expect(status.inner[3], 0x01);
    });

    test('raw data start (0x51) uses revision 2 with a bounded duration', () {
      final f = parseFrame(cmdRawDataStart(1, durationMs: 60000, profile: gen5),
          profile: gen5)!;
      expect(f.opcode, 0x51);
      expect(f.inner[3], 0x02, reason: 'revision 1 would default to a day');
      final bd = ByteData.sublistView(f.inner, 4, 8);
      expect(bd.getUint32(0, Endian.little), 60000);
      // The unbounded day is exactly what the explicit duration exists to avoid.
      expect(() => cmdRawDataStart(1, durationMs: 0, profile: gen5),
          throwsArgumentError);
      expect(() => cmdRawDataStart(1, durationMs: 86400001, profile: gen5),
          throwsArgumentError);
    });

    test('raw data stop (0x52) carries the revision byte', () {
      final f = parseFrame(cmdRawDataStop(1, profile: gen5), profile: gen5)!;
      expect(f.opcode, 0x52);
      expect(f.inner[3], 0x01);
    });

    test('custom advertising name get (0x8D) / set (0x8C)', () {
      final get = parseFrame(cmdGetCustomAdvertisingName(1, profile: gen5),
          profile: gen5)!;
      expect(get.opcode, 0x8D);
      expect(get.inner[3], 0x01);
      final set = parseFrame(
          cmdSetCustomAdvertisingName(1, 'band', profile: gen5),
          profile: gen5)!;
      expect(set.opcode, 0x8C);
      expect(
          set.inner.sublist(3, 13), [0x01, 4, ...'band'.codeUnits, 0, 0, 0, 0]);
      expect(() => cmdSetCustomAdvertisingName(1, '', profile: gen5),
          throwsArgumentError);
      expect(() => cmdSetCustomAdvertisingName(1, 'x' * 32, profile: gen5),
          throwsArgumentError);
    });

    test('config + flag enumerate and get', () {
      final pairs = <int, Uint8List>{
        0x73: cmdGetConfigKeyCount(1, profile: gen5),
        0x75: cmdGetFlagKeyCount(1, profile: gen5),
      };
      pairs.forEach((opcode, frame) {
        final f = parseFrame(frame, profile: gen5)!;
        expect(f.opcode, opcode);
        expect(f.inner[3], 0x01);
      });
      // Cursor-walk iterators: the strap keeps its own position, so the body
      // is just the revision byte — there is no index to send.
      final keyName =
          parseFrame(cmdGetConfigKeyName(1, profile: gen5), profile: gen5)!;
      expect(keyName.opcode, 0x74);
      expect(keyName.inner[3], 0x01);
      final flagName =
          parseFrame(cmdGetFlagKeyName(1, profile: gen5), profile: gen5)!;
      expect(flagName.opcode, 0x76);
      expect(flagName.inner[3], 0x01);
      // By-name reads use the same 32-byte NUL-padded field as the writes.
      for (final (opcode, frame) in [
        (0x79, cmdGetConfigValue(1, 'some_key', profile: gen5)),
        (0x80, cmdGetFlagValue(1, 'some_key', profile: gen5)),
      ]) {
        final f = parseFrame(frame, profile: gen5)!;
        expect(f.opcode, opcode);
        expect(f.inner[3], 0x01);
        expect(
            String.fromCharCodes(
                f.inner.sublist(4, 36).takeWhile((b) => b != 0)),
            'some_key');
      }
    });

    test('event-packet toggle (0x30) sends the bare state, no revision byte',
        () {
      final on = parseFrame(cmdSetEventPackets(1, true, profile: gen5),
          profile: gen5)!;
      expect(on.opcode, 0x30);
      expect(on.inner[3], 0x01, reason: 'state byte, not a revision byte');
      final off = parseFrame(cmdSetEventPackets(1, false, profile: gen5),
          profile: gen5)!;
      expect(off.inner[3], 0x00);
      // A revision byte would push the state one byte too far.
      expect(
          _body(cmdSetEventPackets(1, false, profile: gen5), profile: gen5)
              .sublist(0, 1),
          [0x00]);
    });

    test('AFE get (0x3E) and haptics stop (0x7A)', () {
      for (final (opcode, frame) in [
        (0x3E, cmdGetAfeParams(1, profile: gen5)),
        (0x7A, cmdStopHaptics(1, profile: gen5)),
      ]) {
        final f = parseFrame(frame, profile: gen5)!;
        expect(f.opcode, opcode);
        expect(f.inner[3], 0x01);
      }
    });

    // Filtered reading ("Labrador", R17) — the three lifecycle toggles.
    // Every body is [revision 01][operation]; 124's operation is
    // NOT a boolean.
    test('filtered reading: wrist select + the three toggle bodies', () {
      final wrist = parseFrame(
          cmdSelectWrist(1, WristSelection.left, profile: gen5),
          profile: gen5)!;
      expect(wrist.opcode, 0x7B);
      expect(wrist.inner.sublist(3, 5), [0x01, WristSelection.left.value]);

      // 124: 01 01 stop / 01 02 start / 01 03 restart.
      for (final (op, expected) in [
        (LabradorOperation.stop, [0x01, 0x01]),
        (LabradorOperation.start, [0x01, 0x02]),
        (LabradorOperation.restart, [0x01, 0x03]),
      ]) {
        final f = parseFrame(cmdLabradorDataGeneration(1, op, profile: gen5),
            profile: gen5)!;
        expect(f.opcode, 0x7C, reason: 'TOGGLE_LABRADOR_DATA_GENERATION = 124');
        expect(f.inner.sublist(3, 5), expected, reason: '$op');
      }

      // 125 and 139: 01 00 disable / 01 01 enable.
      for (final (opcode, off, on) in [
        (
          0x7D,
          cmdLabradorRawSave(1, false, profile: gen5),
          cmdLabradorRawSave(1, true, profile: gen5)
        ),
        (
          0x8B,
          cmdLabradorFiltered(1, false, profile: gen5),
          cmdLabradorFiltered(1, true, profile: gen5)
        ),
      ]) {
        final disabled = parseFrame(off, profile: gen5)!;
        expect(disabled.opcode, opcode);
        expect(disabled.inner.sublist(3, 5), [0x01, 0x00]);
        final enabled = parseFrame(on, profile: gen5)!;
        expect(enabled.opcode, opcode);
        expect(enabled.inner.sublist(3, 5), [0x01, 0x01]);
      }
    });

    // The deprecated builders keep their exact old bytes: existing callers are
    // flagged, not silently re-pointed. Two of the three are wrong on the wire
    // — that is what the deprecation says, and this pins it.
    test('deprecated ECG builders still emit their old (wrong) bytes', () {
      // ignore: deprecated_member_use_from_same_package
      final armed = parseFrame(cmdEcgControl(1, true, profile: gen5),
          profile: gen5)!;
      expect(armed.opcode, 0x7C);
      expect(armed.inner.sublist(3, 5), [0x01, 0x01],
          reason: 'the old "arm" is the STOP operation');
      // ignore: deprecated_member_use_from_same_package
      final disarmed = parseFrame(cmdEcgControl(1, false, profile: gen5),
          profile: gen5)!;
      expect(disarmed.inner.sublist(3, 5), [0x01, 0x00],
          reason: 'the old "disarm" is an undefined operation byte');

      // ignore: deprecated_member_use_from_same_package
      final raw =
          parseFrame(cmdEcgSendRaw(1, true, profile: gen5), profile: gen5)!;
      expect(raw.opcode, 0x7E,
          reason: '126 is not an established WHOOP opcode');
      expect(raw.inner.sublist(3, 5), [0x01, 0x01]);

      // 139 was only misnamed — same bytes as the replacement.
      // ignore: deprecated_member_use_from_same_package
      final filtered = cmdEcgSendFiltered(1, true, profile: gen5);
      expect(filtered, cmdLabradorFiltered(1, true, profile: gen5));
      final f = parseFrame(filtered, profile: gen5)!;
      expect(f.opcode, 0x8B);
      expect(f.inner.sublist(3, 5), [0x01, 0x01]);
    });
  });

  group('constants', () {
    test('skin temperature is event 111 and bond-complete is event 31', () {
      expect(EventId.temperatureLevel, 111);
      expect(EventId.bleBonded, 31);
      expect(EventId.name(111), 'TEMPERATURE_LEVEL');
      expect(EventId.name(31), 'BLE_BONDED');
    });

    test('the destructive opcodes are all in the enforced never-send set', () {
      expect(Cmd.persistentOpticalSave, 0x99);
      expect(Cmd.forgetBonds, 0x0F);
      expect(
          dangerousCmds,
          containsAll(<int>[
            Cmd.persistentOpticalSave, // stuck-LED / battery drain
            Cmd.forgetBonds, // forces a full re-pair
            Cmd.setReadPointer, // same 8-byte shape as forceTrim
            Cmd.togglePersistentR21,
            Cmd.forceTrim,
          ]));
    });

    test('gen5 record versions are named, and 24 is flagged gen4-only', () {
      expect(
          [Record.r16, Record.r17, Record.r22, Record.r26], [16, 17, 22, 26]);
      expect(Record.r24, 24);
    });

    test('the gen5 opcodes we can now name', () {
      expect([
        Cmd.setGenericHrProfile,
        Cmd.sendEventPackets,
        Cmd.setAfeParams,
        Cmd.getAfeParams,
        Cmd.startRawData,
        Cmd.stopRawData,
        Cmd.disableBleUart,
        Cmd.saveImuData,
        Cmd.setSignalConfig,
        Cmd.setCustomAdvertisingName,
        Cmd.getCustomAdvertisingName,
        Cmd.wearDetectOverride,
        Cmd.setLedAccessibility,
        Cmd.gyroEnable,
        Cmd.gyroStatus,
      ], [
        0x0E,
        0x30,
        0x3D,
        0x3E,
        0x51,
        0x52,
        0x67,
        0x69,
        0x8A,
        0x8C,
        0x8D,
        0x94,
        0x95,
        0x96,
        0x98,
      ]);
    });
  });
}
