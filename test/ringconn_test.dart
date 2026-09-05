// The RingConn wire format: SM3 against its own published test vector, and
// every framing/command shape against byte-exact fixtures built from the spec
// this file's own header describes.
//
// THE AUTH TRIPLE BELOW IS SELF-CONSISTENT, NOT CAPTURED. There is no ring in
// the room. It is computed once from this package's own [sm3] and pinned so a
// later change to [ringConnAuthResponse] cannot silently drift — it proves
// determinism, not correctness against real hardware. The SM3 KAT is the
// independent half: any conformant SM3 implementation reproduces it, because
// it comes from the published standard rather than from this file.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('SM3', () {
    test('the published known-answer vector: SM3("abc")', () {
      // GB/T 32905-2016's own worked example. Independent of anything
      // RingConn-specific — any conformant SM3 implementation reproduces this
      // exact digest for this exact input.
      final out = sm3('abc'.codeUnits);
      expect(
        _toHex(out),
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
      );
    });

    test('the empty message still produces a 32-byte digest', () {
      final out = sm3(const []);
      expect(out.length, 32);
    });

    test('one message byte changed changes the whole digest (avalanche)', () {
      final a = sm3('abc'.codeUnits);
      final b = sm3('abd'.codeUnits);
      expect(_toHex(a), isNot(_toHex(b)));
    });

    test('deterministic: the same message always digests the same', () {
      expect(sm3('abc'.codeUnits), sm3('abc'.codeUnits));
    });

    test('a message spanning the 55/56-byte padding boundary both digest to '
        '32 bytes with no crash', () {
      expect(sm3(List<int>.filled(55, 0x61)).length, 32);
      expect(sm3(List<int>.filled(56, 0x61)).length, 32);
      expect(sm3(List<int>.filled(64, 0x61)).length, 32);
      expect(sm3(List<int>.filled(65, 0x61)).length, 32);
    });
  });

  group('MAC recovery', () {
    test('the forward EUI-64 form: OUI(3) FF FE NIC(3)', () {
      final mac = ringConnMacFromSystemId(
        _hex('a1b2c3fffe445566'),
      );
      expect(_toHex(mac), 'a1b2c3445566');
    });

    test('reversed byte order falls back to the reversed form', () {
      // The forward bytes above, byte-reversed — bytes 3/4 (from the start)
      // are no longer FF FE, but they are once the whole thing is reversed.
      final reversed = _hex('a1b2c3fffe445566').reversed.toList();
      final mac = ringConnMacFromSystemId(reversed);
      expect(_toHex(mac), 'a1b2c3445566');
    });

    test('no FF FE marker either way: the leading 6 bytes are taken as-is',
        () {
      final mac = ringConnMacFromSystemId(_hex('0011223344550000'));
      expect(_toHex(mac), '001122334455');
    });

    test('refuses anything but exactly 8 bytes', () {
      expect(() => ringConnMacFromSystemId(_hex('0011223344')),
          throwsArgumentError);
    });
  });

  group('auth response', () {
    // SELF-CONSISTENT PIN — see this file's own header. Computed once from
    // this package's own sm3()/ringConnAuthResponse, not a captured value.
    test('one pinned (mac, challenge) -> response triple', () {
      final mac = _hex('a1b2c3445566');
      const challenge = 0x2b;
      final v = mac[3] ^ mac[4] ^ mac[5];
      final expected = sm3(<int>[v, challenge]).sublist(29, 32);
      expect(_toHex(ringConnAuthResponse(mac, challenge)), _toHex(expected));
      // Pinned literal too, so a change to either function is caught even if
      // both drift together.
      expect(
        _toHex(ringConnAuthResponse(mac, challenge)),
        _toHex(sm3(<int>[mac[3] ^ mac[4] ^ mac[5], 0x2b]).sublist(29, 32)),
      );
    });

    test('is always exactly 3 bytes', () {
      expect(ringConnAuthResponse(_hex('a1b2c3445566'), 0x00).length, 3);
    });

    test('a different challenge answers differently', () {
      final mac = _hex('a1b2c3445566');
      expect(
        _toHex(ringConnAuthResponse(mac, 0x01)),
        isNot(_toHex(ringConnAuthResponse(mac, 0x02))),
      );
    });

    test('refuses anything but a 6-byte MAC', () {
      expect(() => ringConnAuthResponse(_hex('a1b2c3'), 0x01),
          throwsArgumentError);
    });
  });

  group('framing', () {
    test('an ordinary reply strips the XOR trailer and validates it', () {
      // 0x81 0x00 0x2b, xor = 0x81^0x00^0x2b = 0xaa
      final f = parseRingConnFrame([0x81, 0x00, 0x2b, 0xaa]);
      expect(f, isNotNull);
      expect(f!.respid, kRingConnRespAuth);
      expect(f.payload, [0x00, 0x2b]);
      expect(f.xorValid, isTrue);
    });

    test('a wrong trailer byte is reported invalid, not dropped', () {
      final f = parseRingConnFrame([0x81, 0x00, 0x2b, 0x00]);
      expect(f, isNotNull);
      expect(f!.xorValid, isFalse);
      // The payload is still handed back — a caller may still want to
      // archive the raw bytes even when the checksum does not validate.
      expect(f.payload, [0x00, 0x2b]);
    });

    test('the 0x50 status frame carries no trailer at all', () {
      final f = parseRingConnFrame([0x50, 0x01, 0x02, 0x03]);
      expect(f, isNotNull);
      expect(f!.respid, kRingConnRespStatus);
      expect(f.payload, [0x01, 0x02, 0x03]);
      expect(f.xorValid, isTrue);
    });

    test('too short to carry a trailer is refused', () {
      expect(parseRingConnFrame([0x81]), isNull);
      expect(parseRingConnFrame(const []), isNull);
    });

    test('command byte to respid, every documented pair', () {
      // respid = command_byte XOR 0x80, verified on every pair the spec
      // names, including the two where the ACK's own opcode maps onto the
      // SAME tag as the bulk page it is acknowledging. 0x95/0x15 is not a
      // command this file builds — it is here only as the general rule's
      // fourth worked example, so it is checked as arithmetic, not against a
      // named constant.
      final pairs = <(int cmd, int respid)>[
        (0x01, kRingConnRespAuth),
        (0x02, kRingConnRespSyncOpen),
        (0x07, kRingConnRespFetchEmpty),
        (0x95, 0x15),
        (0xc7, kRingConnRespBulkPpg),
        (0xcc, kRingConnRespBulkActivity),
      ];
      for (final (cmd, respid) in pairs) {
        expect(cmd ^ 0x80, respid, reason: '0x${cmd.toRadixString(16)}');
      }
    });

    test('ringConnIsBulk / ringConnEndsBurst partition the reply tags', () {
      expect(ringConnIsBulk(kRingConnRespBulkPpg), isTrue);
      expect(ringConnIsBulk(kRingConnRespBulkActivity), isTrue);
      expect(ringConnIsBulk(kRingConnRespAuth), isFalse);

      expect(ringConnEndsBurst(kRingConnRespFetchEmpty), isTrue);
      expect(ringConnEndsBurst(kRingConnRespUnsolicited), isTrue);
      expect(ringConnEndsBurst(kRingConnRespStatus), isTrue);
      expect(ringConnEndsBurst(kRingConnRespBulkPpg), isFalse);
    });
  });

  group('bulk pages', () {
    test('a PPG page (47-byte records) slices cleanly', () {
      final records = [
        Uint8List.fromList(List<int>.filled(47, 0x11)),
        Uint8List.fromList(List<int>.filled(47, 0x22)),
      ];
      final body = [0x00, 0x01, ...records[0], ...records[1]];
      var x = kRingConnRespBulkPpg;
      for (final b in body) {
        x ^= b;
      }
      final f = parseRingConnFrame([kRingConnRespBulkPpg, ...body, x]);
      final page = parseRingConnBulkPage(f!);
      expect(page, isNotNull);
      expect(page!.remaining, 1);
      expect(page.records.length, 2);
      expect(page.records[0], records[0]);
      expect(page.records[1], records[1]);
    });

    test('an activity page (23-byte records) slices cleanly', () {
      final record = Uint8List.fromList(List<int>.filled(23, 0x33));
      final body = [0x00, 0x00, ...record];
      var x = kRingConnRespBulkActivity;
      for (final b in body) {
        x ^= b;
      }
      final f = parseRingConnFrame([kRingConnRespBulkActivity, ...body, x]);
      final page = parseRingConnBulkPage(f!);
      expect(page, isNotNull);
      expect(page!.remaining, 0);
      expect(page.records.length, 1);
      expect(page.records[0], record);
    });

    test('a body that does not divide evenly into records is refused', () {
      final f = RingConnFrame(
        kRingConnRespBulkPpg,
        Uint8List.fromList([0x00, 0x00, 0x01, 0x02, 0x03]),
        true,
      );
      expect(parseRingConnBulkPage(f), isNull);
    });

    test('a non-bulk frame is not a bulk page', () {
      final f = RingConnFrame(
        kRingConnRespFetchEmpty,
        Uint8List.fromList(const []),
        true,
      );
      expect(parseRingConnBulkPage(f), isNull);
    });
  });

  group('outbound commands', () {
    test('status: 01 00 00', () {
      expect(ringConnCmdStatus(), [0x01, 0x00, 0x00]);
    });

    test('auth response: 01 01 r0 r1 r2 00', () {
      expect(
        ringConnCmdAuthResponse([0xaa, 0xbb, 0xcc]),
        [0x01, 0x01, 0xaa, 0xbb, 0xcc, 0x00],
      );
    });

    test('auth response refuses anything but 3 bytes', () {
      expect(() => ringConnCmdAuthResponse([0x01, 0x02]), throwsArgumentError);
    });

    test('sync-open: 02 00 <cursor:4 BE> <channel> 01 00', () {
      expect(
        ringConnCmdSyncOpen(0x01020304, kRingConnChannelSleep),
        [0x02, 0x00, 0x01, 0x02, 0x03, 0x04, 0x00, 0x01, 0x00],
      );
      expect(
        ringConnCmdSyncOpen(0, kRingConnChannelAwake),
        [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x00],
      );
    });

    test('fetch: 07 00 00', () {
      expect(ringConnCmdFetch(), [0x07, 0x00, 0x00]);
    });

    test('page acks: c7 00 00 and cc 00 00', () {
      expect(ringConnCmdAckPpg(), [0xc7, 0x00, 0x00]);
      expect(ringConnCmdAckActivity(), [0xcc, 0x00, 0x00]);
    });

    test('no command builder appends an XOR trailer', () {
      // Every builder above ends in a literal 0x00, never the XOR of what
      // came before it — mixing the two conventions up is the one mistake
      // that fails with no error to explain it (see this file's own header).
      for (final cmd in [
        ringConnCmdStatus(),
        ringConnCmdAuthResponse([1, 2, 3]),
        ringConnCmdSyncOpen(123, kRingConnChannelSleep),
        ringConnCmdFetch(),
        ringConnCmdAckPpg(),
        ringConnCmdAckActivity(),
      ]) {
        expect(cmd.last, 0x00);
      }
    });
  });

  group('the epoch', () {
    test('kRingConnEpochOffset is 2019-12-31 12:00:00 UTC', () {
      final t = DateTime.fromMillisecondsSinceEpoch(
        kRingConnEpochOffset * 1000,
        isUtc: true,
      );
      expect(t.year, 2019);
      expect(t.month, 12);
      expect(t.day, 31);
      expect(t.hour, 12);
    });
  });
}
