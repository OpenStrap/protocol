import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('load data payload layout', () {
    final p = FwUpdate.loadDataPayload(0x01020304, [9, 8, 7]);
    expect(p, [0x01, 0x04, 0x03, 0x02, 0x01, 3, 9, 8, 7]);
  });
  test('rejects empty and oversize chunks', () {
    expect(() => FwUpdate.loadDataPayload(0, const []), throwsArgumentError);
    expect(() => FwUpdate.loadDataPayload(0, List.filled(256, 0)),
        throwsArgumentError);
  });
  test('rejects offsets outside u32', () {
    expect(() => FwUpdate.loadDataPayload(-1, [1]), throwsArgumentError);
    expect(() => FwUpdate.loadDataPayload(0x100000000, [1]), throwsArgumentError);
  });
  test('chunk count rejects empty and negative lengths', () {
    expect(() => FwUpdate.chunkCount(0), throwsArgumentError);
    expect(() => FwUpdate.chunkCount(-5), throwsArgumentError);
  });
  test('chunk count rounds up', () {
    expect(FwUpdate.chunkCount(128), 1);
    expect(FwUpdate.chunkCount(129), 2);
  });
  test('start, load and process are blocked by the generic guard', () {
    for (final op in [FwUpdate.startLoad, FwUpdate.loadData, FwUpdate.processImage]) {
      expect(dangerousCmds.contains(op), isTrue);
    }
  });
}
