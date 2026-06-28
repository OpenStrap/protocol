// parse_hello serial/commit extraction — validated against REAL captured HELLO
// responses (whoop_capture.jsonl, band serial "4C2248092"). The serial lives at a
// fixed NUL-terminated offset (payload[16]); the old "first printable run" scan
// latched onto the volatile binary header and surfaced "?*" junk on some firmware.

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  // The three GET_HELLO_HARVARD response *bodies* (inner[3:]) captured live.
  // They differ only in the volatile header bytes [0:16]; the serial is always
  // the NUL-terminated token at offset 16.
  const helloBodies = [
    'a001048303000000b196e201b0020000344332323438303932003865323738326237'
        '346634303238346333663437363138623062613234373663356431366363303533'
        '313862373532316431353635650600000002000000100000002900000011000000'
        '060000000000000008060000000000000011000000020000000200000000000000',
    '0001048303000000b196e20150460000344332323438303932003865323738326237'
        '346634303238346333663437363138623062613234373663356431366363303533'
        '313862373532316431353635650600000002000000100000002900000011000000'
        '060000000000000008060000000000000011000000020000000200000000000000',
    'a00104c503000000ef77256a087d0000344332323438303932003865323738326237'
        '346634303238346333663437363138623062613234373663356431366363303533'
        '313862373532316431353635650600000002000000100000002900000011000000'
        '060000000000000008060000000000000011000000020000000200000000000000',
  ];

  test('serial is read at the fixed offset on every real capture', () {
    for (final body in helloBodies) {
      final h = parseHello(hexToBytes(body));
      expect(h.serial, '4C2248092',
          reason: 'serial must be the offset-16 NUL-terminated token');
    }
  });

  test('commit hex follows the serial', () {
    final h = parseHello(hexToBytes(helloBodies.first));
    expect(h.commit, isNotNull);
    expect(h.commit!.startsWith('8e2782b7'), isTrue);
    expect(h.commit!.length >= 16, isTrue);
  });

  test('no serial = no junk (short HELLO body returns null, never "?*")', () {
    // The short HELLO from the parity fixtures — no serial token present.
    const shortBody = '0291021f038d025e01000b010c020c0100000000160001510c'
        '000000000000';
    final h = parseHello(hexToBytes(shortBody));
    expect(h.serial, isNull);
  });

  test('renamed-band advertised name is irrelevant to serial parsing', () {
    // Sanity: a body whose header bytes happen to be printable must NOT be
    // mistaken for the serial — only the offset-16 token counts.
    final h = parseHello(hexToBytes(helloBodies[1])); // header has "PF" @12
    expect(h.serial, '4C2248092');
  });

  group('advertising name decode', () {
    // inner = [0x24, seq=0x65, 0x4C(opcode)] + body
    String? name(String bodyHex) {
      final inner = hexToBytes('24654c$bodyHex');
      return parseCommandResponse(inner)?.decoded['strap_name'] as String?;
    }

    test('real capture body → clean name', () {
      // [01 01 01 01][len=0e]["Abdul's WHOOP"][00 00 00]
      expect(name('010101010e416264756c27732057484f4f50000000'),
          "Abdul's WHOOP");
    });

    test('no NUL terminator + trailing high bytes → no junk', () {
      // header + len=05 + "PROBE" + high bytes (no NUL). Bounded by len; high
      // bytes dropped → must not leak "?*".
      expect(name('0101010105' '50524f4245' 'fffe2a3f'), 'PROBE');
    });

    test('embedded high byte inside name is dropped, not rendered as "?"', () {
      // len=06, name bytes "AB"+0xFF+"CDE" → printable-only keeps "ABCDE".
      expect(name('0101010106' '4142ff434445' '00'), 'ABCDE');
    });
  });
}
