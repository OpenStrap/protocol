// Byte-conformance pins against the literal wire examples in the WHOOP 5.0
// BLE reference docs: every builder with a documented example body is
// asserted byte-for-byte, so a drive-by edit to a builder cannot silently
// change what goes on the wire.
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

String hx(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('canonical GET_HELLO frame, seq 1, byte-for-byte', () {
    // doc: aa0108000001e671 23019101 363e5c8d
    expect(hx(gen5ClientHello(seq: 1)), 'aa0108000001e67123019101363e5c8d');
  });

  test('ENTER_HIGH_FREQ_SYNC typical body 02 b4 00 20 1c', () {
    final f = parseFrame(
        cmdEnterHighFreqSync(1,
            intervalSeconds: 180,
            durationSeconds: 7200,
            profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    // inner: [35][seq][96][02 b4 00 20 1c]
    expect(f.inner[0], 35);
    expect(f.inner[2], 96);
    expect(hx(Uint8List.fromList(f.inner.sublist(3, 8))), '02b400201c');
  });

  test('gen5 HISTORICAL_DATA_RESULT failure body is exactly 00 00', () {
    final f = parseFrame(buildHistoryResultFail(1, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(f.inner[2], 23);
    expect(f.inner.sublist(3, 5), [0x00, 0x00]);
  });

  test('success result = 01 + markerA + markerB, 9 bytes verbatim',
      () {
    final token = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04];
    final f = parseFrame(
        buildHistoryResultOk(1, token, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(f.inner.sublist(3, 12), [0x01, ...token]);
  });

  test('SET_ALARM_TIME rev-4 body is EXACTLY 21 bytes per the map', () {
    final when = DateTime.fromMillisecondsSinceEpoch(1787153377 * 1000 + 500);
    final f = parseFrame(cmdSetAlarm(1, when, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    final body = f.inner.sublist(3);
    // 04 01 | epoch u32le | subsec u16le | 2f 98 00*6 | 00 00 | 07 | 1e | 00
    expect(body.length, 21, reason: '21 bytes, never 20 — the serializer trap');
    expect(body[0], 0x04, reason: 'revision');
    expect(body[1], 0x01, reason: 'alarm ID 1');
    final epoch = body[2] | body[3] << 8 | body[4] << 16 | body[5] << 24;
    expect(epoch, 1787153377);
    final subsec = body[6] | body[7] << 8;
    expect(subsec, (500 * 32768) ~/ 1000);
    expect(body.sublist(8, 16), [0x2f, 0x98, 0, 0, 0, 0, 0, 0],
        reason: 'waveform effects');
    expect(body.sublist(16, 18), [0, 0], reason: 'per-effect loop control');
    expect(body[18], 0x07, reason: 'overall waveform loop control');
    expect(body[19], 0x1e, reason: '30 s duration cap');
    expect(body[20], 0x00, reason: 'alarm type 0 — the 21st byte IS on the wire');
  });

  test('GET_ALARM_TIME 04 01 / RUN_ALARM 02 01 / DISABLE 02 ff', () {
    final g = parseFrame(cmdGetAlarmTime(1, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(g.inner.sublist(3, 5), [0x04, 0x01]);
    final r = parseFrame(cmdRunAlarm(1, mode: 1, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(r.inner.sublist(3, 5), [0x02, 0x01]);
    final d = parseFrame(cmdDisableAlarm(1, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(d.inner.sublist(3, 5), [0x02, 0xff]);
  });

  test('Maverick haptic body 01 2f 98 00*8 …loop', () {
    final f = parseFrame(cmdBuzzGen5Maverick(1, overallLoop: 1),
        profile: BandProfile.gen5)!;
    expect(hx(Uint8List.fromList(f.inner.sublist(3, 15))),
        '012f98000000000000000001');
  });

  test('SET_CLOCK body = u32 sec + u32 subsec (8 bytes)', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1787153377 * 1000 + 250);
    final f = parseFrame(cmdSetClock(1, now: now, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(f.inner[2], 10, reason: 'SET_CLOCK(10), not 146');
    final body = f.inner.sublist(3, 11);
    final sec = body[0] | body[1] << 8 | body[2] << 16 | body[3] << 24;
    expect(sec, 1787153377);
    final sub = body[4] | body[5] << 8 | body[6] << 16 | body[7] << 24;
    expect(sub, (250 * 32768) ~/ 1000);
  });

  test('GET_CLOCK(11) empty body; GET_DATA_RANGE(34) empty on gen5',
      () {
    final c = parseFrame(cmdGetClock(1, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(c.inner[2], 11);
    // EMPTY body: inner is [35][seq][11] padded to the 4-byte boundary with
    // zeros — any real body byte here would be a doc deviation.
    expect(c.inner.length, 4);
    expect(c.inner[3], 0, reason: 'alignment padding, not a body byte');
    final r = parseFrame(cmdGetDataRangeGen5(1), profile: BandProfile.gen5)!;
    expect(r.inner[2], 34);
    expect(r.inner.length, 4);
    expect(r.inner[3], 0, reason: 'alignment padding, not a body byte');
  });

  test('toggles — 3 bare bool; 106/107 rev+bool; labrador ops', () {
    final hr = parseFrame(cmdToggleHr(1, true), profile: BandProfile.gen4)!;
    expect(hr.inner.sublist(2, 4), [3, 0x01], reason: 'opcode 3 takes bare 01');
    final imu = parseFrame(cmdToggleImu(1, true, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(imu.inner.sublist(3, 5), [0x01, 0x01]);
    final lab = parseFrame(
        cmdLabradorDataGeneration(1, LabradorOperation.start,
            profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(lab.inner[2], 124);
    expect(lab.inner.sublist(3, 5), [0x01, 0x02], reason: 'start = 01 02');
    final raw = parseFrame(
        cmdLabradorRawSave(1, true, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(raw.inner[2], 125);
    expect(raw.inner.sublist(3, 5), [0x01, 0x01]);
  });

  test('battery pack info body 01 on opcode 151', () {
    final f = parseFrame(cmdGetBatteryPackInfo(1, profile: BandProfile.gen5),
        profile: BandProfile.gen5)!;
    expect(f.inner[2], 151);
    expect(f.inner[3], 0x01);
  });
}
