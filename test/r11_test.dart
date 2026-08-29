import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

// R11 (0x2B/0x0B) container decode. No real R11 capture is checked into this
// repo, so this pins the parse math against synthetic bytes: 100 int32-LE
// samples at frame-abs [36:436], split into two 50-sample channels — see
// R11Raw's doc comment (protocol#25) for why, and for what is NOT claimed
// about the signal's meaning.
void main() {
  test('decodeR11Raw reads two 50-sample int32-LE channels', () {
    final b = List<int>.filled(436, 0);
    b[0] = 0x2b;
    b[1] = 0x0b;
    // ts u32 LE @ 7
    const ts = 31624534;
    b[7] = ts & 0xff;
    b[8] = (ts >> 8) & 0xff;
    b[9] = (ts >> 16) & 0xff;
    b[10] = (ts >> 24) & 0xff;

    void putI32(int off, int v) {
      b[off] = v & 0xff;
      b[off + 1] = (v >> 8) & 0xff;
      b[off + 2] = (v >> 16) & 0xff;
      b[off + 3] = (v >> 24) & 0xff;
    }

    // channel A: 150000 + i ; channel B: -2 + i (exercise the sign bit)
    for (int i = 0; i < 50; i++) {
      putI32(36 + 4 * i, 150000 + i);
      putI32(236 + 4 * i, -2 + i);
    }
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    final r = decodeR11Raw(hex);
    expect(r, isNotNull);
    expect(r!.ts, ts);
    expect(r.channelA.length, 50);
    expect(r.channelB.length, 50);
    expect(r.channelA.first, 150000);
    expect(r.channelA.last, 150049);
    expect(r.channelB.first, -2);
    expect(r.channelB.last, 47);
  });

  test('decodeR11Raw rejects non-R11 and short input', () {
    expect(decodeR11Raw('2f1805f1'), isNull); // wrong pkt/rec
    expect(decodeR11Raw('2b0b'), isNull); // too short
  });
}
