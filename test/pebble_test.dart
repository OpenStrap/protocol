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
