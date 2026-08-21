// Control-plane field offsets. A COMMAND_RESPONSE (0x24) inner is
//   [type][strap seq][opcode][echoed request seq][status][body…]
// — a FIVE-byte header — and `parseCommandResponse` hands decoders
// `payload = inner[3:]`, so payload[0] is the echoed seq, payload[1] the
// status, and the command's real body starts at payload[2]. Several decoders
// were written against body-relative indices and read two bytes early; two
// others scanned for a field instead of reading it and locked onto a value
// that straddles the header. EVENT (0x30) and CONSOLE_LOGS (0x32) share a
// different envelope with no such header.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

List<int> le32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

List<int> le16(int v) => [v & 0xff, (v >> 8) & 0xff];

/// A COMMAND_RESPONSE frame's inner bytes: 5-byte header, then [body].
Uint8List cmdResponse(int opcode, List<int> body,
        {int reqSeq = 0x11, int status = 1, int strapSeq = 0x42}) =>
    Uint8List.fromList([0x24, strapSeq, opcode, reqSeq, status, ...body]);

/// An EVENT-envelope packet (used by both 0x30 and 0x32):
/// `[type][u8 seq][u16 id][u32 unix][u16 subsec][u16 body len][body…]`.
/// [pad] is appended AFTER the declared body, as frame padding.
Uint8List envelopePacket(int type, int id, List<int> body,
        {int seq = 0x05,
        int unix = 1786000000,
        int subsec = 0,
        int? declaredLen,
        List<int> pad = const []}) =>
    Uint8List.fromList([
      type,
      seq,
      ...le16(id),
      ...le32(unix),
      ...le16(subsec),
      ...le16(declaredLen ?? body.length),
      ...body,
      ...pad,
    ]);

/// The 65-byte GET_DATA_RANGE reply body.
List<int> dataRangeBody({
  int revision = 1,
  int rawOldPage = 10,
  int readPage = 20,
  int writePage = 30,
  int trimPage = 40,
  int wrapCount = 3,
  int totalPages = 131072,
  int usedRecords = 4567,
  int freeRecords = 89012,
  int oldest = 1780000000,
  int trimTs = 1781000000,
  int currentRead = 1782000000,
  int newest = 1786000000,
}) =>
    [
      revision,
      ...le32(rawOldPage),
      ...le32(readPage),
      ...le32(writePage),
      ...le32(trimPage),
      ...le32(wrapCount),
      ...le32(totalPages),
      ...le32(usedRecords),
      ...le32(freeRecords),
      ...le32(oldest), ...le32(11), // oldest (sec, subsec)
      ...le32(trimTs), ...le32(22), // trim
      ...le32(currentRead), ...le32(33), // current read
      ...le32(newest), ...le32(44), // newest
    ];

void main() {
  group('GET_CLOCK reads the clock field, never a straddle', () {
    test('gen4 (0x0B) epoch is the u32 at payload[2], not the one at [1]', () {
      const sec = 1786000000;
      final r = parseCommandResponse(
          cmdResponse(Cmd.getClock, [...le32(sec), ...le32(9999)]))!;
      expect(r.decoded['clock_epoch'], sec);

      // The value a byte-wise scan would have returned first: [status][sec b0]
      // [sec b1][sec b2]. It is inside the plausible window for every current
      // wall-clock time, which is why the old scan essentially never returned
      // the real clock.
      final straddle = 1 | ((sec & 0xFFFFFF) << 8);
      expect(straddle, greaterThan(1700000000));
      expect(straddle, lessThan(4102444800));
      expect(r.decoded['clock_epoch'], isNot(straddle));
    });

    test('gen5 (0x93) epoch is the u32 at payload[3], after the revision byte',
        () {
      const sec = 1786000123;
      final r = parseCommandResponse(
          cmdResponse(Cmd.getClockGen5, [1, ...le32(sec), ...le16(500)]),
          profile: BandProfile.gen5)!;
      expect(r.decoded['clock_epoch'], sec);
    });

    test('gen5 reply with an unknown revision byte emits nothing', () {
      final r = parseCommandResponse(
          cmdResponse(Cmd.getClockGen5, [7, ...le32(1786000000), ...le16(0)]),
          profile: BandProfile.gen5)!;
      expect(r.decoded.containsKey('clock_epoch'), isFalse);
    });

    test('an implausible epoch emits nothing rather than a guess', () {
      final r = parseCommandResponse(
          cmdResponse(Cmd.getClock, [...le32(0), ...le32(0)]))!;
      expect(r.decoded.containsKey('clock_epoch'), isFalse);
      final short = parseCommandResponse(cmdResponse(Cmd.getClock, [0x01]))!;
      expect(short.decoded.containsKey('clock_epoch'), isFalse);
    });
  });

  group('GET_DATA_RANGE', () {
    test('emits oldest/newest from payload[35] and payload[59]', () {
      final r = parseCommandResponse(cmdResponse(
          Cmd.getDataRange,
          dataRangeBody(
            oldest: 1780000000,
            newest: 1786000000,
          )))!;
      // Both offsets are ≡ 3 (mod 4), so the old 4-byte-grid scan from
      // payload[0] could never land on either and emitted nothing at all.
      expect(r.decoded['range_oldest'], 1780000000);
      expect(r.decoded['range_newest'], 1786000000);
    });

    test('pages_behind reads the ring-buffer fields at the real offsets', () {
      final r = parseCommandResponse(cmdResponse(
          Cmd.getDataRange,
          dataRangeBody(
            writePage: 30,
            trimPage: 40,
            wrapCount: 3,
            totalPages: 131072,
            usedRecords: 4567,
            freeRecords: 89012,
          )))!;
      expect(r.decoded['pages_behind'], {
        'written': 30, // WritePage   @ payload[11]
        'used': 4567, // UsedRecords @ payload[27]
        'capacity': 131072, // TotalPages  @ payload[23]
        'trim_page': 40, // TrimPage    @ payload[15]
        'wrap_count': 3, // WrapCount   @ payload[19]
        'free_records': 89012, // FreeRecords @ payload[31]
      });
    });

    test('a capacity other than the usual one still decodes', () {
      final r = parseCommandResponse(cmdResponse(
          Cmd.getDataRange, dataRangeBody(totalPages: 65536, writePage: 7)))!;
      expect((r.decoded['pages_behind'] as Map)['capacity'], 65536);
      expect((r.decoded['pages_behind'] as Map)['written'], 7);
    });

    test('an unknown revision byte emits neither range nor backlog', () {
      final r = parseCommandResponse(
          cmdResponse(Cmd.getDataRange, dataRangeBody(revision: 9)))!;
      expect(r.decoded.containsKey('range_oldest'), isFalse);
      expect(r.decoded.containsKey('pages_behind'), isFalse);
    });

    test('implausible values degrade to nothing', () {
      final r = parseCommandResponse(cmdResponse(Cmd.getDataRange,
          dataRangeBody(oldest: 0, newest: 5, totalPages: 0)))!;
      expect(r.decoded.containsKey('range_oldest'), isFalse);
      expect(r.decoded.containsKey('range_newest'), isFalse);
      expect(r.decoded.containsKey('pages_behind'), isFalse);
    });

    test('a write page beyond capacity is not reported as backlog', () {
      final r = parseCommandResponse(cmdResponse(Cmd.getDataRange,
          dataRangeBody(writePage: 200000, totalPages: 131072)))!;
      expect(r.decoded.containsKey('pages_behind'), isFalse);
    });
  });

  // The alarm/haptics status byte: the SET and RUN
  // alarm replies both carry a haptics/alarm status at response-body offset 1,
  // i.e. payload[3]. It is "in addition to" the outer command result — the two
  // answer different questions and both have to be read.
  group('alarm replies carry a status byte of their own', () {
    Map<String, dynamic> setReply(int status, {int outer = 1, int rev = 3}) =>
        parseCommandResponse(
                cmdResponse(Cmd.setAlarmTime, [rev, status], status: outer))!
            .decoded;

    Map<String, dynamic> runReply(int status, {int outer = 1}) =>
        parseCommandResponse(
                cmdResponse(Cmd.runAlarm, [2, status], status: outer))!
            .decoded;

    test('SET_ALARM_TIME(66) reads body byte 1, past the revision byte', () {
      final ok = setReply(AlarmStatus.validInputPattern);
      expect(ok['alarm_status'], 1);
      expect(ok['alarm_status_name'], 'valid_input_pattern');

      final played = setReply(AlarmStatus.playedSuccessfully);
      expect(played['alarm_status'], 5);
      expect(played['alarm_status_name'], 'played_successfully');
    });

    test('a rejected alarm time is reported even under a SUCCESS outer result',
        () {
      // The case the whole branch exists for: the outer result says the
      // command was handled, and the strap still refused the alarm.
      final r = setReply(AlarmStatus.invalidAlarmTime);
      expect(r['cmd_status'], 1);
      expect(r['alarm_status'], 10);
      expect(r['alarm_status_name'], 'invalid_alarm_time');
      expect(AlarmStatus.isInputRejection(10), isTrue);
    });

    test('a FAILURE reply still yields its status — that is the diagnostic',
        () {
      final r = setReply(AlarmStatus.invalidAlarmId, outer: 0);
      expect(r['cmd_status'], 0);
      expect(r['alarm_status'], 11);
      expect(r['alarm_status_name'], 'invalid_alarm_id');
    });

    test('an unrecognised response revision does not suppress the status', () {
      // The SET reply's revision byte reads 3, but it is not a gate: a strap
      // answering with another revision still put the status where it goes.
      expect(setReply(AlarmStatus.hapticsBusy, rev: 9)['alarm_status'], 8);
    });

    test('RUN_ALARM(68) decodes the same table from its [02, status] body', () {
      expect(runReply(AlarmStatus.playedSuccessfully)['alarm_status_name'],
          'played_successfully');
      expect(runReply(AlarmStatus.hapticsFailure)['alarm_status'], 6);
      // Run-time outcomes are NOT input rejections — a busy strap is not a
      // strap that refused the request.
      expect(AlarmStatus.isInputRejection(AlarmStatus.hapticsBusy), isFalse);
      expect(AlarmStatus.isInputRejection(AlarmStatus.hapticsStopped), isFalse);
    });

    test('an undocumented code stays numeric rather than being guessed at', () {
      expect(runReply(200)['alarm_status_name'], 'code_200');
      expect(AlarmStatus.isInputRejection(200), isFalse);
    });

    test('a body too short to hold the status emits nothing at all', () {
      // Header + revision byte only: there is no status byte to read.
      final short =
          parseCommandResponse(cmdResponse(Cmd.setAlarmTime, [3]))!.decoded;
      expect(short.containsKey('alarm_status'), isFalse);
      expect(short.containsKey('alarm_status_name'), isFalse);
      expect(short['cmd_status'], 1, reason: 'the outer result still decodes');

      final empty =
          parseCommandResponse(cmdResponse(Cmd.runAlarm, const []))!.decoded;
      expect(empty.containsKey('alarm_status'), isFalse);
    });

    test('GET_ALARM_TIME rev-4 reports active only when the flag is exactly 1',
        () {
      Map<String, dynamic> get4(int activeFlag) => parseCommandResponse(
            cmdResponse(Cmd.getAlarmTime,
                [0x04, activeFlag, ...le32(1786000000), ...le16(0)]),
          )!.decoded;
      expect(get4(1)['alarm_active'], isTrue);
      expect(get4(1)['alarm_epoch'], 1786000000);
      expect(get4(0)['alarm_active'], isFalse);
      // Anything other than exactly 1 is not an armed alarm.
      expect(get4(2)['alarm_active'], isFalse);
    });

    test('gen5 GET_CUSTOM_ADVERTISING_NAME (0x8D) decodes like gen4 0x4C', () {
      // Reply body: revision, status, length, then the ASCII name — the same
      // shape at the same offsets on both generations.
      const name = 'Band-7';
      final body = [0x01, 0x00, name.length, ...name.codeUnits];
      final g5 = parseCommandResponse(
          cmdResponse(Cmd.getCustomAdvertisingName, body),
          profile: BandProfile.gen5)!;
      final g4 = parseCommandResponse(
          cmdResponse(Cmd.getAdvertisingNameHarvard, body))!;
      expect(g5.decoded['strap_name'], name);
      expect(g4.decoded['strap_name'], name);
    });
  });

  group('EVENT (0x30) body is bounded by the declared length', () {
    test('frame padding past the length field is not part of the body', () {
      final e = parseEvent(envelopePacket(0x30, EventId.setRtc, [0xAA, 0xBB],
          pad: [0x00, 0x00, 0x00]))!;
      expect(e.body, [0xAA, 0xBB]);
    });

    test('a declared length longer than the frame is clamped, not thrown', () {
      final e = parseEvent(envelopePacket(0x30, EventId.setRtc, [0xAA],
          declaredLen: 64))!;
      expect(e.body, [0xAA]);
    });

    test('BATTERY_LEVEL charging comes from body[9], not the always-zero [10]',
        () {
      List<int> batteryBody(int chargerFlag) => [
            2, // revision
            ...le32(855), // state of charge ×10
            ...le32(3900), // millivolts
            chargerFlag, // [9]
            0, // [10] — always zero
            ...List<int>.filled(8, 0), // packed pairs
          ];
      final on = parseEvent(
          envelopePacket(0x30, EventId.batteryLevel, batteryBody(1)))!;
      expect(on.decoded['battery_pct'], closeTo(85.5, 1e-9));
      expect(on.decoded['battery_mv'], 3900);
      expect(on.decoded['charging'], isTrue);

      final off = parseEvent(
          envelopePacket(0x30, EventId.batteryLevel, batteryBody(0)))!;
      expect(off.decoded['charging'], isFalse);
    });
  });

  // Field-level bodies exist for four event ids the
  // decoder used to hand back raw. All offsets below are BODY-relative (the
  // envelope body starts at inner[12]).
  group('volunteered EVENT bodies are decoded (gen5)', () {
    List<int> conditionBody({
      int pagesBehind = 1234,
      int backlogTenths = 456,
      int socTenths = 872,
      int flash = 3,
      int charging = 1,
      int wrist = 2,
    }) =>
        [
          ...le32(pagesBehind),
          ...le16(backlogTenths),
          ...le16(socTenths),
          flash,
          charging,
          wrist,
        ];

    test('STRAP_CONDITION_REPORT(29) reports backlog, charge and wear', () {
      final e = parseEvent(
          envelopePacket(0x30, EventId.strapConditionReport, conditionBody()),
          profile: BandProfile.gen5)!;
      expect(e.name, 'STRAP_CONDITION_REPORT');
      expect(e.decoded['condition_pages_behind'], 1234);
      expect(e.decoded['condition_backlog'], closeTo(45.6, 1e-9));
      expect(e.decoded['condition_soc_pct'], closeTo(87.2, 1e-9));
      expect(e.decoded['condition_flash'], 3);
      expect(e.decoded['condition_charging'], isTrue);
      // Tri-state, kept raw — the doc names no mapping, and wear truth is not
      // taken from here.
      expect(e.decoded['condition_wrist_state'], 2);
      expect(e.decoded.containsKey('on_wrist'), isFalse);
    });

    test('a state of charge outside 0..100 is not reported at all', () {
      final e = parseEvent(
          envelopePacket(0x30, EventId.strapConditionReport,
              conditionBody(socTenths: 0xFFFF)),
          profile: BandProfile.gen5)!;
      expect(e.decoded.containsKey('condition_soc_pct'), isFalse);
      // The fields around it still decode.
      expect(e.decoded['condition_pages_behind'], 1234);
      expect(e.decoded['condition_charging'], isTrue);
    });

    test('a short STRAP_CONDITION_REPORT body degrades to its prefix', () {
      final e = parseEvent(
          envelopePacket(0x30, EventId.strapConditionReport,
              conditionBody().sublist(0, 6)),
          profile: BandProfile.gen5)!;
      expect(e.decoded['condition_pages_behind'], 1234);
      expect(e.decoded['condition_backlog'], closeTo(45.6, 1e-9));
      expect(e.decoded.containsKey('condition_soc_pct'), isFalse);
      expect(e.decoded.containsKey('condition_charging'), isFalse);
    });

    test('HAPTICS_TERMINATED(100) separates expiry, error and dismissal', () {
      Map<String, dynamic> terminated(int code) => parseEvent(
              envelopePacket(0x30, EventId.hapticsTerminated, [1, code]),
              profile: BandProfile.gen5)!
          .decoded;

      expect(terminated(0)['haptics_termination'], 'expired');
      expect(terminated(1)['haptics_termination'], 'error');
      // The one the wearer causes: a double tap on a running alarm.
      final tap = terminated(2);
      expect(tap['haptics_revision'], 1);
      expect(tap['haptics_termination_code'], HapticsTermination.userDoubleTap);
      expect(tap['haptics_termination'], 'user_double_tap');
      // An undocumented code stays numeric rather than being folded into one
      // of the three known causes.
      expect(terminated(9)['haptics_termination'], 'code_9');
    });

    test('BATTERY_PACK_INFO(109) decodes address, name and hardware', () {
      final body = <int>[
        4, // [0] revision
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // [1..6] BT address
        ...'PACK-7'.codeUnits, // [7..] name, NUL padded to 22
        ...List<int>.filled(16 - 'PACK-7'.length, 0),
        ...le16(742), // [23..24] battery-level structure
        5, // [25] colorway
        2, // [26] hardware family
      ];
      final e = parseEvent(envelopePacket(0x30, EventId.batteryPackInfo, body),
          profile: BandProfile.gen5)!;
      expect(e.name, 'BATTERY_PACK_INFO');
      expect(e.decoded['pack_revision'], 4);
      expect(e.decoded['pack_address'], 'aa:bb:cc:dd:ee:ff');
      expect(e.decoded['pack_name'], 'PACK-7');
      expect(e.decoded['pack_battery_raw'], 742);
      expect(e.decoded['pack_colorway'], 5);
      expect(e.decoded['pack_hardware_family'], 2);
    });

    test('a truncated BATTERY_PACK_INFO body decodes nothing, never garbage',
        () {
      final e = parseEvent(
          envelopePacket(
              0x30, EventId.batteryPackInfo, List<int>.filled(20, 0x41)),
          profile: BandProfile.gen5)!;
      expect(e.decoded, isEmpty);
      expect(e.body, hasLength(20)); // still retained raw
    });

    test('GENERIC_FIRMWARE_EVENT(123) names sub-id 6 and numbers the rest', () {
      final dorset = parseEvent(
          envelopePacket(0x30, EventId.genericFirmwareEvent, [1, ...le16(6)]),
          profile: BandProfile.gen5)!;
      expect(dorset.decoded['fw_event_revision'], 1);
      expect(dorset.decoded['fw_event_id'], FirmwareEventId.dorsetDetected);
      expect(dorset.decoded['fw_event'], 'DORSET_DETECTED');

      final other = parseEvent(
          envelopePacket(0x30, EventId.genericFirmwareEvent, [1, ...le16(300)]),
          profile: BandProfile.gen5)!;
      expect(other.decoded['fw_event_id'], 300);
      expect(other.decoded['fw_event'], 'FIRMWARE_EVENT_300');
    });

    test('the gen5-scoped ids stay numeric and un-decoded on a gen4 parse', () {
      // A gen4 event 29 is not a known vocabulary entry — decoding it with
      // the gen5 body map would turn an unknown byte into a confident wrong
      // number (a fabricated state of charge, above all).
      final e = parseEvent(
          envelopePacket(0x30, EventId.strapConditionReport, conditionBody()))!;
      expect(e.name, 'EVENT_${EventId.strapConditionReport}');
      expect(e.decoded, isEmpty);
      final h = parseEvent(
          envelopePacket(0x30, EventId.hapticsTerminated, [1, 2]))!;
      expect(h.name, 'EVENT_${EventId.hapticsTerminated}');
      expect(h.decoded, isEmpty);
    });

    test('an event id outside the vocabulary still flows through as an event',
        () {
      // Unlisted event ids: 110 and 124 arrive with no vocabulary entry.
      // They must stay retainable burst members, not become `event_unparsed`.
      final e = parseEvent(
          envelopePacket(0x30, 110, [0x01, 0x01, 0, 0, 0, 0, 0, 0]))!;
      expect(e.eventId, 110);
      expect(e.name, 'EVENT_110');
      expect(e.decoded, isEmpty);
      expect(e.body, hasLength(8));

      final d = decodeFrame(Frame(
          envelopePacket(0x30, 124, [0x01, 0x01, 0x01, 0x03]), true, true));
      expect(d.kind, 'event');
      expect(d.fields['retain_raw'], isTrue);
    });
  });

  group('CONSOLE_LOGS (0x32) uses the event envelope', () {
    Uint8List logPacket(int seq, String text, {List<int> pad = const []}) =>
        envelopePacket(0x32, 2, text.codeUnits, seq: seq, pad: pad);

    test('record_index is the u8 seq, not a u16 over seq + event id', () {
      final c = parseConsoleLog(logPacket(5, 'hi'))!;
      expect(c.recordIndex, 5);
      // The old u16 read picked up the event id's low byte too.
      expect(c.recordIndex, isNot(5 | 0x0200));
    });

    test('the first character of the text is text, not a channel byte', () {
      const line = '146552119: BLE_CMD: Command Send Historical Data\n';
      final c = parseConsoleLog(logPacket(9, line))!;
      expect(c.text, line);
      expect(c.chunkLen, line.length);
    });

    test('text is bounded by chunk_len, so frame padding never leaks in', () {
      final c = parseConsoleLog(logPacket(1, 'abc', pad: [0x41, 0x42]))!;
      expect(c.text, 'abc');
    });

    test('an empty chunk decodes instead of returning null', () {
      final c = parseConsoleLog(logPacket(2, ''))!;
      expect(c.text, '');
      expect(c.recordIndex, 2);
    });

    test('reassembly is contiguous over the u8 counter, wrapping at 0xFF', () {
      final r = ConsoleLogReassembler();
      expect(r.add(parseConsoleLog(logPacket(0xFE, 'a'))!), isFalse);
      expect(r.add(parseConsoleLog(logPacket(0xFF, 'b'))!), isTrue);
      expect(r.add(parseConsoleLog(logPacket(0x00, 'c'))!), isTrue);
      expect(r.flush(), 'abc');
    });

    test('a gap hands back the run it ended instead of eating it', () {
      // add() used to clear the buffer itself, so by the time the caller saw
      // the false return the earlier line was already gone.
      final r = ConsoleLogReassembler();
      r.add(parseConsoleLog(logPacket(5, 'BLE_CMD: Command Send '))!);
      r.add(parseConsoleLog(logPacket(6, 'Historical Data\n'))!);
      expect(r.add(parseConsoleLog(logPacket(9, 'after the gap'))!), isFalse);
      expect(r.flush(), 'BLE_CMD: Command Send Historical Data\n');
      expect(r.add(parseConsoleLog(logPacket(10, '!'))!), isTrue);
      expect(r.flush(), 'after the gap!');
    });
  });

  group('HELLO battery scan starts on the body, not the status byte', () {
    test('a status of 1 next to a small body byte is not a battery level', () {
      // payload[1] = status 1, payload[2] = 2 → the old scan read u16@1 =
      // 0x0201 = 513 → a confident 51.3%. The real field is at payload[3].
      final payload = Uint8List.fromList([
        0x77, // echoed request seq
        0x01, // status = ok
        0x02, // body[0]
        0x83, 0x03, // body[1:3] = 899 → 89.9%
        ...List<int>.filled(8, 0x00),
      ]);
      final h = parseHello(payload);
      expect(h.batteryPct, closeTo(89.9, 1e-9));
    });
  });
}
