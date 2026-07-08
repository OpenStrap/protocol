// Feed REAL captured command-response frames (HELLO + GET_ADVERTISING_NAME)
// through the actual FrameReassembler + decodeFrame under adversarial BLE
// chunking — whole-frame, one giant chunk, byte-by-byte, and split-across-frames.
// Reproduces the "first read correct, second read garbled (esp. name)" report if
// the reassembler carries state between reads.

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

// Full on-wire frames from whoop_capture.jsonl (band serial 4C2248092, renamed
// "Abdul's WHOOP"). Order matches capture: HELLO, HELLO, ADVNAME, HELLO.
const frames = <String>[
  'aa8c004a246323a001048303000000b196e201b00200003443323234383039320038653237383262373466343032383463336634373631386230626132343736633564313663633035333138623735323164313536356506000000020000001000000029000000110000000600000000000000080600000000000000110000000200000002000000000000000e3ddd35',
  'aa8c004a2464230001048303000000b196e20150460000344332323438303932003865323738326237346634303238346333663437363138623062613234373663356431366363303533313862373532316431353635650600000002000000100000002900000011000000060000000000000008060000000000000011000000020000000200000000000000f107c6a5',
  'aa1c00ab24654c010101010e416264756c27732057484f4f50000000c1f64786',
  'aa8c004a242723a00104c503000000ef77256a087d0000344332323438303932003865323738326237346634303238346333663437363138623062613234373663356431366363303533313862373532316431353635650600000002000000100000002900000011000000060000000000000008060000000000000011000000020000000200000000000000ebc0d3a1',
];

const expectedSerial = '4C2248092';
const expectedName = "Abdul's WHOOP";

// Run all frame bytes through one reassembler using [chunker] to split the byte
// stream, then decode every valid frame and collect serials + names.
({List<String> serials, List<String> names}) run(
    List<List<int>> Function(List<int>) chunker) {
  final asm = FrameReassembler();
  final serials = <String>[];
  final names = <String>[];
  final stream = <int>[];
  for (final f in frames) {
    stream.addAll(hexToBytes(f));
  }
  for (final chunk in chunker(stream)) {
    for (final frame in asm.feed(chunk)) {
      if (!frame.valid) continue;
      final d = decodeFrame(frame);
      if (d.kind != 'cmd_response') continue;
      final hello = d.fields['hello'];
      if (hello is HelloInfo && hello.serial != null) serials.add(hello.serial!);
      final nm = d.fields['strap_name'];
      if (nm is String && nm.isNotEmpty) names.add(nm);
    }
  }
  return (serials: serials, names: names);
}

void main() {
  final chunkers = <String, List<List<int>> Function(List<int>)>{
    'one big chunk': (s) => [s],
    'byte by byte': (s) => [for (final b in s) [b]],
    'mtu 20': (s) => [
          for (var i = 0; i < s.length; i += 20) s.sublist(i, (i + 20).clamp(0, s.length))
        ],
    'mtu 23 (split frames)': (s) => [
          for (var i = 0; i < s.length; i += 23) s.sublist(i, (i + 23).clamp(0, s.length))
        ],
  };

  chunkers.forEach((name, chunker) {
    test('every read is clean under chunking: $name', () {
      final r = run(chunker);
      expect(r.serials.length, greaterThanOrEqualTo(3),
          reason: 'all 3 HELLOs should decode');
      for (final s in r.serials) {
        expect(s, expectedSerial, reason: 'serial must never garble on a repeat');
      }
      expect(r.names, isNotEmpty);
      for (final n in r.names) {
        expect(n, expectedName, reason: 'name must never garble on a repeat');
      }
    });
  });
}
