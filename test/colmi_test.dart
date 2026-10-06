import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

/// A Service A reply frame: [cmd, ...body] zero-padded, checksum appended.
List<int> frame(int cmd, List<int> body) => colmiFrame(cmd, body);

/// A Service B reply around [payload], with a correct CRC.
List<int> big(int type, List<int> payload) =>
    colmiBigDataRequest(type, payload);

void main() {
  group('framing', () {
    test('16 bytes, checksum is the low byte of the sum of 0-14', () {
      final f = colmiFrame(0x03);
      expect(f, hasLength(16));
      expect(f[15], 0x03);
      expect(colmiFrameValid(f), isTrue);
      expect(colmiFrameValid([...f.sublist(0, 15), 0x04]), isFalse);
    });

    test('payload over 14 bytes is refused', () {
      expect(() => colmiFrame(1, List.filled(15, 0)), throwsArgumentError);
    });

    test('set time is BCD local wall clock', () {
      final f = colmiSetTimeRequest(DateTime(2026, 10, 4, 21, 7, 59));
      expect(f.sublist(0, 7), [0x01, 0x26, 0x10, 0x04, 0x21, 0x07, 0x59]);
      // Language byte after the clock: English, not the zero default.
      expect(f[7], 1);
    });

    test('SetTime reply byte 9 says which sleep protocol the ring speaks', () {
      final reply = List<int>.filled(14, 0);
      expect(colmiNewSleepProtocol(frame(0x01, reply)), isFalse);
      reply[8] = 1;
      expect(colmiNewSleepProtocol(frame(0x01, reply)), isTrue);
      expect(colmiNewSleepProtocol(frame(0x03, reply)), isNull);
    });

    test('reboot and factory reset are flagged destructive', () {
      expect(colmiIsDestructive(colmiFrame(0x08)), isTrue);
      expect(colmiIsDestructive(colmiFrame(0xff)), isTrue);
      expect(colmiIsDestructive(colmiBatteryRequest()), isFalse);
    });

    test('history requests', () {
      expect(colmiActivityRequest(3).sublist(0, 6),
          [0x43, 3, 0x0f, 0x00, 0x5f, 0x01]);
      expect(colmiHrHistoryRequest(0x01020304).sublist(0, 5),
          [0x15, 0x04, 0x03, 0x02, 0x01]);
      expect(colmiHrvRequest(2).sublist(0, 5), [0x39, 2, 0, 0, 0]);
      expect(colmiStressRequest(3).sublist(0, 2), [0x37, 3]);
      expect(colmiSleepDetailsRequest(2).sublist(0, 5),
          [0x44, 2, 0x0f, 0x00, 0x5f]);
    });

    test('big-data requests carry CRC-16/MODBUS of the payload', () {
      final crcSleep = crc16Modbus([0xff, 0x01]);
      expect(colmiSleepRequest(), [
        0xbc, 0x27, 0x02, 0x00, crcSleep & 0xff, crcSleep >> 8, 0xff, 0x01, //
      ]);
      expect(colmiSpo2Request(), [0xbc, 0x2a, 0x01, 0x00, 0xff, 0x00, 0xff]);
      // Full sync asks for every stored day (6).
      expect(colmiTemperatureRequest().sublist(0, 4), [0xbc, 0x25, 0x01, 0x00]);
      expect(colmiTemperatureRequest().last, 6);
      expect(colmiTemperatureRequest(0).last, 0);
    });
  });

  group('reassembly', () {
    test('a reply split over three notifications comes back whole', () {
      final whole = big(kColmiBigSleep, List.generate(40, (i) => i));
      final r = ColmiBigDataReassembler();
      expect(r.add(whole.sublist(0, 20)), isNull);
      expect(r.pending, isTrue);
      expect(r.add(whole.sublist(20, 39)), isNull);
      expect(r.add(whole.sublist(39)), whole);
      expect(r.pending, isFalse);
      expect(colmiBigDataCrcOk(whole), isTrue);
    });

    test('a non-0xbc chunk with nothing pending is dropped', () {
      expect(ColmiBigDataReassembler().add([0x01, 2, 3, 4, 5, 6, 7]), isNull);
    });

    test('a corrupted payload fails the CRC', () {
      final whole = big(kColmiBigSpo2, [1, 2, 3]);
      whole[7] ^= 0xff;
      expect(colmiBigDataCrcOk(whole), isFalse);
    });
  });

  group('service A history', () {
    test('battery', () {
      expect(colmiBatteryPct(frame(0x03, [87, 0])), 87);
      expect(colmiBatteryPct(frame(0x03, [187])), isNull);
    });

    test('HR: page 1 after a 4-byte timestamp, later pages from byte 2', () {
      expect(colmiHrHistoryPoints(frame(0x15, [0x00, 24])), isEmpty);
      expect(colmiHrHistoryPoints(frame(0x15, [0xff])), isEmpty);
      final p1 = colmiHrHistoryPoints(
          frame(0x15, [1, 0xaa, 0xbb, 0xcc, 0xdd, 60, 0, 62]));
      expect(p1.map((p) => (p.minuteOfDay, p.value)), [(0, 60), (10, 62)]);
      // Page 2 starts after page 1's 9 slots = 45 min.
      final p2 = colmiHrHistoryPoints(frame(0x15, [2, 70]));
      expect(p2.single.minuteOfDay, 45);
      // Page 3 starts after 9 + 13 slots = 110 min.
      expect(
          colmiHrHistoryPoints(frame(0x15, [3, 71])).single.minuteOfDay, 110);
    });

    test('stress and HRV: 30-min slots, 12 on page 1, 13 after', () {
      final s1 = colmiStressPoints(frame(0x37, [1, 0x99, 40, 41]));
      expect(s1.map((p) => (p.minuteOfDay, p.value)), [(0, 40), (30, 41)]);
      expect(colmiStressPoints(frame(0x37, [2, 50])).single.minuteOfDay, 360);
      expect(colmiHrvPoints(frame(0x39, [4, 33])).single.minuteOfDay,
          (12 + 13 * 2) * 30);
    });

    test('page 0 carries the page count and the slot interval', () {
      final h = colmiPagedHeader(frame(0x15, [0, 25, 10]), 0x15)!;
      expect((h.pages, h.slotMinutes), (25, 10));
      expect(colmiPagedHeader(frame(0x15, [1, 25, 10]), 0x15), isNull);
      // A 10-minute HR interval: page 2 starts after 9 slots = 90 min.
      expect(
          colmiHrHistoryPoints(frame(0x15, [2, 70]), slotMinutes: 10)
              .single
              .minuteOfDay,
          90);
      expect(
          colmiStressPoints(frame(0x37, [2, 50]), slotMinutes: 15)
              .single
              .minuteOfDay,
          180);
    });

    test('page 1 says which day the walk is for', () {
      expect(
          colmiHrPageTimestamp(frame(0x15, [1, 0x04, 0x03, 0x02, 0x01, 60])),
          0x01020304);
      expect(colmiHrPageTimestamp(frame(0x15, [1, 0, 0, 0, 0, 60])), isNull);
      expect(colmiPagedDaysAgo(frame(0x37, [1, 3, 40])), 3);
      expect(colmiPagedDaysAgo(frame(0x39, [1, 2, 40])), 2);
      expect(colmiPagedDaysAgo(frame(0x39, [2, 2, 40])), isNull);
    });

    test('points past midnight are never emitted', () {
      // Page 4 of a 30-min walk ends at slot 50 > 48.
      final p = colmiStressPoints(frame(0x37, [4, ...List.filled(13, 9)]));
      expect(p.every((x) => x.minuteOfDay < 1440), isTrue);
      expect(p, hasLength(10));
    });

    test('a frame with a bad checksum decodes to nothing', () {
      final f = frame(0x15, [1, 0, 0, 0, 0, 60]);
      f[15] ^= 1;
      expect(colmiHrHistoryPoints(f), isEmpty);
    });

    test('activity: BCD date, quarter-hour slot, little-endian counters', () {
      final s = colmiActivitySlot(frame(0x43, [
        0x26, 0x10, 0x04, 37, 1, 4, //
        0x10, 0x00, 0x34, 0x12, 0x20, 0x00,
      ]))!;
      expect((s.year, s.month, s.day), (2026, 10, 4));
      expect(s.minuteOfDay, 37 * 15);
      expect(s.steps, 0x1234);
      expect(s.calories, 0x10);
      expect(s.distance, 0x20);
      expect(s.isLast, isFalse);
      expect(colmiActivitySlot(frame(0x43, [0xf0])), isNull);
      expect(colmiActivityDone(frame(0x43, [0xff])), isTrue);
      // The header's byte 3 == 1 means calories are in tenths.
      expect(colmiActivityCaloriesX10(frame(0x43, [0xf0, 5, 1])), isTrue);
      expect(colmiActivityCaloriesX10(frame(0x43, [0xf0, 5, 0])), isFalse);
      expect(colmiActivityCaloriesX10(frame(0x43, [0x26])), isNull);
      final x10 = colmiActivitySlot(
          frame(0x43, [0x26, 0x10, 0x04, 37, 1, 4, 0x10, 0x00]),
          caloriesX10: true)!;
      expect(x10.calories, 160);
      expect(
          colmiActivityDone(frame(0x43, [0x26, 0x10, 0x04, 37, 3, 4])), isTrue);
    });
  });

  test('sleep detail rows: BCD date, slot, seven quality bytes', () {
    final f = frame(0x44, [0x26, 0x10, 0x04, 88, 2, 3, 1, 2, 3, 4, 5, 6, 7]);
    final r = colmiSleepDetailRow(f)!;
    expect((r.year, r.month, r.day, r.timeIndex), (2026, 10, 4, 88));
    expect(r.qualities, [1, 2, 3, 4, 5, 6, 7]);
    expect(colmiSleepDetailsDone(f), isTrue);
    expect(
        colmiSleepDetailsDone(
            frame(0x44, [0x26, 0x10, 0x04, 88, 1, 3, 1, 2, 3, 4, 5, 6, 7])),
        isFalse);
    expect(colmiSleepDetailRow(frame(0x44, [0xf0])), isNull);
    expect(colmiSleepDetailsDone(frame(0x44, [0xff])), isTrue);
  });

  group('service B history', () {
    test('sleep: two nights, one starting the evening before', () {
      final r = big(kColmiBigSleep, [
        2, // nights
        1, 8, 0x8e, 0x05, 0x6e, 0x01, kColmiStageLight, 120, kColmiStageDeep,
        0, // night 1: 23:10 -> 06:06, 120 light, 0-min block dropped
        0, 10, 0x1e, 0x00, 0xb4, 0x00, kColmiStageRem, 30, kColmiStageAwake,
        5, kColmiStageLight, 115, // night 2: 00:30 -> 03:00
      ]);
      final n = colmiSleepNights(r);
      expect(n, hasLength(2));
      expect(n[0].daysAgo, 1);
      expect(n[0].startMinute, 1422);
      expect(n[0].endMinute, 366);
      expect(n[0].startsDayBefore, isTrue);
      expect(n[0].blocks.map((b) => (b.stage, b.minutes)),
          [(kColmiStageLight, 120)]);
      expect(n[1].startsDayBefore, isFalse);
      expect(n[1].blocks, hasLength(3));
    });

    test('sleep: a truncated night is dropped, not guessed', () {
      final r = big(kColmiBigSleep, [1, 0, 20, 0, 0, 10, 0, 2, 30]);
      expect(colmiSleepNights(r), isEmpty);
    });

    test('sleep: naps decode from their own reply type, tagged', () {
      final r = big(kColmiBigNap, [
        1, 0, 8, 0xd0, 0x02, 0x0c, 0x03, kColmiStageLight, 40, 0, 20,
      ]);
      final n = colmiSleepNights(r).single;
      expect(n.nap, isTrue);
      expect(n.startMinute, 720);
      expect(n.totalMinutes, 60);
      expect(colmiSleepNights(big(kColmiBigSleep, [
        1, 0, 6, 0, 0, 0x68, 0x01, kColmiStageDeep, 30,
      ])).single.nap, isFalse);
    });

    test('SpO2: 49-byte day blocks of 24 hourly (max, min), any order', () {
      List<int> day(int ago) => [
            ago,
            for (var h = 0; h < 24; h++) ...(h == 3 ? [98, 95] : [0, 0]),
          ];
      // Today first: nothing after it may be dropped.
      final hours = colmiSpo2Hours(big(kColmiBigSpo2, [...day(0), ...day(1)]));
      expect(hours.map((h) => (h.daysAgo, h.hour, h.min, h.max)),
          [(0, 3, 95, 98), (1, 3, 95, 98)]);
      // A partial trailing block is dropped, not half-read.
      expect(
          colmiSpo2Hours(big(kColmiBigSpo2, [...day(1), 0, 99, 97])),
          hasLength(1));
    });

    test('temperature: one day per reply, slots of timeSpan minutes', () {
      final t = colmiTemperatures(big(kColmiBigTemperature, [
        2, 30, //
        for (var k = 0; k < 48; k++) k == 4 ? 150 : (k == 5 ? 160 : 0),
      ]));
      expect(t.map((x) => (x.daysAgo, x.minuteOfDay, x.celsius)),
          [(2, 120, 35.0), (2, 150, 36.0)]);
    });

    test('temperature: a 60-minute day of 24 slots is read, not dropped', () {
      final t = colmiTemperatures(big(kColmiBigTemperature, [
        0, 60, for (var k = 0; k < 24; k++) k == 23 ? 140 : 0,
      ]));
      expect(t.single.minuteOfDay, 23 * 60);
      expect(t.single.celsius, closeTo(34.0, 1e-9));
    });

    test('temperature: a partial day yields the slots it has', () {
      final t = colmiTemperatures(big(kColmiBigTemperature, [0, 30, 0, 150]));
      expect(t.single.minuteOfDay, 30);
      expect(colmiTemperatures(big(kColmiBigTemperature, [0, 30])), isEmpty);
    });

    test('temperature: the run-length +32 encoding', () {
      final t = colmiTemperatures(
          big(kColmiBigTemperature, [1, 30, 0x80 + 10, 45, 0x80 + 2, 50]),
          encoding: ColmiTempEncoding.runLengthPlus32);
      expect(t.map((x) => x.minuteOfDay), [300, 390]);
      expect(t[0].celsius, closeTo(36.5, 1e-9));
      expect(t[1].celsius, closeTo(37.0, 1e-9));
    });
  });
}
