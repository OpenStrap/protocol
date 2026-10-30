import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

List<int> u16(int v) => [v & 0xff, v >> 8];
List<int> u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24];

void main() {
  test('inner frames: BE length + endpoint, reassembled across packets', () {
    final f = pebbleFrame(kPebbleEndpointDatalog, List.generate(40, (i) => i));
    expect(f.sublist(0, 4), [0, 40, 0x1a, 0x7a]);
    final packets = pebblePpogattPackets(f, 30);
    expect(packets.first.first, 30 << 3);
    expect(packets[2].first, 0 << 3, reason: 'serials are 5-bit and wrap');
    final r = PebbleFrameReassembler();
    final out = [for (final p in packets) ...r.add(p.sublist(1))];
    expect(out.single.$1, kPebbleEndpointDatalog);
    expect(out.single.$2, List.generate(40, (i) => i));
  });

  group('reassembler recovery', () {
    // A 66-byte datalog data frame split into 20-byte packets, and two small
    // whole frames that follow it.
    final a = pebbleFrame(kPebbleEndpointDatalog,
        [2, 1, ...List.filled(60, 0x5a)]);
    final b = pebbleFrame(kPebbleEndpointDatalog, [2, 1, ...List.filled(30, 1)]);
    final c = pebbleFrame(kPebbleEndpointDatalog, [2, 2, ...List.filled(30, 2)]);

    List<(int, Uint8List)> feed(PebbleFrameReassembler r, List<List<int>> ps) =>
        [for (final p in ps) ...?r.addPacket(p)];

    test('reset drops a partial frame cut by a transport reset', () {
      final r = PebbleFrameReassembler();
      expect(r.addPacket(pebblePpogattPackets(a, 0).first), isEmpty);
      r.reset();
      final out = feed(r, [
        ...pebblePpogattPackets(b, 0),
        ...pebblePpogattPackets(c, 2),
      ]);
      expect(out.map((f) => f.$2[1]), [1, 2]);
      expect(out.map((f) => f.$2.length), [32, 32]);
    });

    test('a repeated serial is dropped, not appended twice', () {
      final r = PebbleFrameReassembler();
      final ps = pebblePpogattPackets(b, 30);
      expect(r.addPacket(ps[0]), isEmpty);
      // Not null: the repeat still has to be acked.
      expect(r.addPacket(ps[0]), isEmpty);
      final out = feed(r, ps.skip(1).toList());
      expect(out.single.$2, [2, 1, ...List.filled(30, 1)]);
    });

    test('a re-send of the frame-completing packet is acked, not re-emitted',
        () {
      final r = PebbleFrameReassembler();
      final ps = pebblePpogattPackets(b, 6);
      expect(feed(r, ps).single.$2, [2, 1, ...List.filled(30, 1)]);
      // The ack for the last packet was lost, so the watch re-sends it.
      for (var i = 0; i < 3; i++) {
        expect(r.addPacket(ps.last), isEmpty);
      }
      final next = feed(r, pebblePpogattPackets(c, 6 + ps.length));
      expect(next.single.$2[1], 2);
    });

    test('go-back-N re-send after lost acks keeps the frame intact', () {
      final r = PebbleFrameReassembler();
      final pa = pebblePpogattPackets(a, 0); // serials 0..3
      final pc = pebblePpogattPackets(c, pa.length);
      // 0,1,2 arrive; the acks for 1 and 2 are lost, so the watch re-sends
      // from 1 onward, then the next frame.
      for (final p in [pa[0], pa[1], pa[2]]) {
        expect(r.addPacket(p), isEmpty);
      }
      // Both re-sends were already taken: acked (not null), not re-appended.
      expect(r.addPacket(pa[1]), isEmpty);
      expect(r.addPacket(pa[2]), isEmpty);
      final out = feed(r, [pa[3], ...pc]);
      expect(out.map((f) => f.$2.length), [62, 32]);
      expect(out.first.$2, [2, 1, ...List.filled(60, 0x5a)]);
      expect(out.last.$2[1], 2);
    });

    test('a serial behind the last one is not acked unless it was taken', () {
      final r = PebbleFrameReassembler();
      final pa = pebblePpogattPackets(a, 5);
      expect(r.addPacket(pa[0]), isEmpty);
      // Serial 4 was never taken in this session, so it is not a repeat.
      expect(r.addPacket(pebblePpogattPackets(b, 4).first), isNull);
    });

    test('a skipped packet is dropped until it is re-sent in order', () {
      final r = PebbleFrameReassembler();
      final pa = pebblePpogattPackets(a, 0);
      // packet 1 is skipped; 2 and 3 arrive out of order and are dropped,
      // then go-back-N re-sends 1, 2, 3.
      expect(r.addPacket(pa[0]), isEmpty);
      expect(r.addPacket(pa[2]), isNull);
      expect(r.addPacket(pa[3]), isNull);
      final out = feed(r, [pa[1], pa[2], pa[3]]);
      expect(out.single.$2, [2, 1, ...List.filled(60, 0x5a)]);
    });
  });

  test('phone version reply: 25 bytes, Android, LE capability mask', () {
    final v = pebblePhoneVersionReply();
    expect(v, hasLength(25));
    expect(v.sublist(9, 13), [0, 0, 0, 2]);
    expect(v[17], 0xaf); // 0x1|0x2|0x4|0x8|0x20|0x80
  });

  test('set time: UTC seconds BE, offset minutes BE', () {
    final now = DateTime.utc(2026, 10, 4, 1, 0).toLocal();
    final v = pebbleSetTimeUtc(now);
    final utc = now.millisecondsSinceEpoch ~/ 1000;
    expect(v.sublist(0, 5),
        [3, utc >> 24, (utc >> 16) & 0xff, (utc >> 8) & 0xff, utc & 0xff]);
    expect(v[7], 0);
  });

  test('datalog open and data', () {
    final open = [1, 7, ...List.filled(16, 0), ...u32(1), ...u32(81), 0, ...u16(4)];
    final s = parsePebbleDatalogOpen(open)!;
    expect((s.sid, s.tag, s.itemSize, s.system), (7, 81, 4, true));
    final app = [...open]..[5] = 0xab;
    expect(parsePebbleDatalogOpen(app)!.system, isFalse);
    final data = [2, 7, ...u32(0), ...u32(0), 1, 2, 3, 4, 5, 6, 7, 8];
    expect(parsePebbleDatalogItems(data, 4), [[1, 2, 3, 4], [5, 6, 7, 8]]);
    expect(parsePebbleDatalogItems([...data, 9], 4), isNull);
    expect(pebbleDatalogAck(7), [0x85, 7]);
  });

  test('steps item v7: per-minute steps and HR from the header timestamp', () {
    List<int> rec(int steps, int hr) =>
        [steps, 0, ...u16(300), 10, 0, ...u16(0), ...u16(0), ...u16(0), hr];
    final item = [...u16(7), ...u32(1791000000), 0, 13, 2, ...rec(12, 58), ...rec(0, 0)];
    final m = parsePebbleStepsItem(item)!;
    expect(m.map((x) => (x.tsSec, x.steps, x.hr)),
        [(1791000000, 12, 58), (1791000060, 0, null)]);
    expect(parsePebbleStepsItem([...u16(99), ...item.sublist(2)]), isNull);
    expect(parsePebbleStepsItem(item.sublist(0, item.length - 1)), isNull,
        reason: 'cut short of its record count');
    expect(() => pebblePpogattPackets([1, 2], 0, maxPacket: 1),
        throwsArgumentError);
  });

  test('overlay: deep sleep period', () {
    final o = parsePebbleOverlayItem(
        [...u16(1), ...u16(0), ...u16(2), ...u32(0), ...u32(1791000000), ...u32(3600)])!;
    expect((o.type, o.startSec, o.durationSec), (2, 1791000000, 3600));
  });
}
