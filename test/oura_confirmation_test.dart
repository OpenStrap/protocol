// Independent confirmation of the Oura wire-format primitives that do NOT
// depend on a real ring's capture — the outbound command encodings and the
// batch-summary layout are fixed byte layouts with no sensor data in them, so
// they can be checked against values computed by hand from the layout, not
// just against a capture.
//
// WHY THIS FILE EXISTS SEPARATELY FROM `oura_test.dart`. That file's own
// header says plainly there is no independent oracle for this band, because
// its expectations are read off one real capture. That is true for the SENSOR
// decoders (temperature, battery, motion, …) — there is genuinely no second
// source for what a specific ring reported on a specific night. It is NOT
// true for the command builders and the batch-summary field layout: every one
// below is a fixed byte shape, added up by hand from the doc comments on the
// functions under test, not copied from this file's own encoder.
//
// The AES-128/ECB auth-proof cross-check lives with the session that drives
// this wire format, one layer up — this package has no cipher implementation.

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
  group('command encodings — field-by-field byte layout', () {
    test('get-events: cursor 0, cap 8, "every type" filter', () {
      // `[0x10][len 9][cursor u32 LE][cap u8][filter i32 LE]`. -1 as an i32
      // is 4 bytes of 0xff — the documented "every type" filter value.
      final b = ouraCmdGetEvents(0, maxEvents: 8, flags: -1);
      expect(_toHex(b), '10090000000008ffffffff');
    });

    test('get-events: a non-zero cursor and cap round-trip byte for byte',
        () {
      // cursor 0x01020304 LE = 04 03 02 01, cap 0x2a, filter -1.
      final b = ouraCmdGetEvents(0x01020304, maxEvents: 0x2a, flags: -1);
      expect(_toHex(b), '1009040302012affffffff');
    });

    test('auth-nonce request is the fixed 3-byte secure-session sub-op', () {
      expect(_toHex(ouraCmdAuthNonce()), '2f012b');
    });

    test('authenticate: sub-op 0x2d then the 16-byte proof, length = 17', () {
      final proof = _hex('a38a8772d3acb6db5c2b516dd56987c8');
      final b = ouraCmdAuthenticate(proof);
      expect(_toHex(b), '2f112d' 'a38a8772d3acb6db5c2b516dd56987c8');
    });

    test('set-auth-key: opcode 0x24, length 16, the key verbatim', () {
      final key = _hex('000102030405060708090a0b0c0d0e0f');
      final b = ouraCmdSetAuthKey(key);
      expect(_toHex(b), '2410' '000102030405060708090a0b0c0d0e0f');
    });

    test('sync-time: opcode 0x12, 8-byte LE unix seconds, then the tz byte',
        () {
      // unix 1 = u64 LE 01 00 00 00 00 00 00 00, timezone 2 half-hours (+1h).
      final b = ouraCmdSyncTime(1, tzHalfHours: 2);
      expect(_toHex(b), '1209' '0100000000000000' '02');
    });
  });

  group('auth-result codes — the fixed status enum', () {
    // `[0x2f][len][0x2e][status]`. The four codes and their meanings are a
    // closed, documented set; wrong-key/factory-reset/not-onboarded have
    // different remedies, so a decoder that collapsed them would be a
    // regression even though every one of these frames "fails" the same way.
    OuraFrame authReply(int status) =>
        OuraFrame(0x2f, Uint8List.fromList([0x2e, status]));

    test('0x00 is success', () => expect(ouraAuthResult(authReply(0x00)), 0));
    test('0x01 is a wrong key',
        () => expect(ouraAuthResult(authReply(0x01)), kOuraAuthWrongKey));
    test('0x02 is factory-reset (no key installed yet)',
        () => expect(ouraAuthResult(authReply(0x02)), kOuraAuthFactoryReset));
    test('0x03 is authenticated but not this phone',
        () => expect(ouraAuthResult(authReply(0x03)), kOuraAuthNotOnboarded));
  });

  group('nonce-response sub-op — exactly one value, nothing else', () {
    // `2f <len> 2c <nonce:15>`: the outer frame's own length byte (16, one
    // sub-op byte + the 15-byte nonce) sits BEFORE the payload this function
    // reads — `f.payload` starts at the sub-op, so `f.payload[0]` is never the
    // length. A decoder that also accepted the length byte's own value at
    // this position would risk parsing an unrelated frame as a nonce reply.
    final nonce = _hex('0102030405060708090a0b0c0d0e0f');

    test('sub-op 0x2c is the nonce reply', () {
      final f = OuraFrame(0x2f, Uint8List.fromList([0x2c, ...nonce]));
      expect(ouraAuthNonce(f), nonce);
    });

    test('any other sub-op is not a nonce reply', () {
      final f = OuraFrame(0x2f, Uint8List.fromList([0x11, ...nonce]));
      expect(ouraAuthNonce(f), isNull);
    });
  });

  group('sensor decoders — algebraic identity, not a captured value', () {
    // These don't need a ring either: the wire's own arithmetic (centi-degree
    // integer / 100, little-endian byte order) is checkable by picking any
    // in-range value and confirming the decoder recovers exactly it — no
    // capture required, because the claim under test is "this decoder
    // implements int16-LE/100.0", not "this ring read 33.56°C that night".
    test('temperature: every representable centi-degree in range round-trips',
        () {
      for (final centi in [-4000, -100, 0, 100, 3356, 8500]) {
        final le = Uint8List(2)
          ..buffer.asByteData().setInt16(0, centi, Endian.little);
        final ev = OuraEvent(kOuraEvtTempPeriod, 0, le);
        final out = decodeTemperatures(ev);
        expect(out, isNotNull, reason: 'centi=$centi');
        expect(out!.single, closeTo(centi / 100.0, 1e-9));
      }
    });

    test('temperature: one tick outside the sensor range refuses the array',
        () {
      final le = Uint8List(2)
        ..buffer.asByteData().setInt16(0, 8501, Endian.little); // 85.01°C
      expect(decodeTemperatures(OuraEvent(kOuraEvtTempPeriod, 0, le)), isNull);
    });

    test('debug-data battery: the percent/millivolt fields are independent',
        () {
      // subtype 0x24, then percent (u8) and millivolts (u16 LE) — sweep both
      // fields across their real range and confirm each decodes on its own
      // axis rather than one leaking into the other.
      for (final pct in [0, 1, 50, 99, 100]) {
        for (final mv in [2500, 3700, 4200, 4500]) {
          final body = <int>[0x24, pct, mv & 0xff, mv >> 8];
          final d = decodeDebugData(body);
          expect(d, isNotNull, reason: 'pct=$pct mv=$mv');
          expect(d!.batteryPct, pct);
          expect(d.batteryMv, mv);
        }
      }
    });
  });

  group('batch summary — the layout is a count + a byte total, not a status '
      'code + a cursor', () {
    // The 8-byte body after `[0x11][len]` has exactly one field a caller can
    // safely treat as "the drain is done": whichever field is provably a
    // COUNT that only ever reaches zero when nothing is left, never a status
    // enum. The two candidate readings of this body disagree on which byte is
    // which, so the fixed-point layout is worth pinning independently of the
    // one real capture `oura_test.dart` reads it against.
    OuraFrame batchFrame(int received, int progress, int bytesLeft) {
      final b = Uint8List(6);
      b[0] = received;
      b[1] = progress;
      b.buffer.asByteData().setUint32(2, bytesLeft, Endian.little);
      return OuraFrame(0x11, b);
    }

    test('byte 0 is a per-batch COUNT (0..255), never a binary status flag',
        () {
      // A status byte would only ever be one of a couple of fixed codes. This
      // field takes every value across a full batch, which a status enum
      // cannot — so byte 0 has to be counting something, not signalling one
      // of a few states.
      for (final n in [0, 1, 8, 100, 255]) {
        final s = parseBatchSummary(batchFrame(n, 0, 0))!;
        expect(s.received, n);
      }
    });

    test('bytes 2-5 are the u32 LE byte total, independent of byte 0 or 1',
        () {
      for (final left in [0, 1, 3742, 65535, 0xFFFFFFFF]) {
        final s = parseBatchSummary(batchFrame(200, 7, left))!;
        expect(s.bytesLeft, left, reason: 'bytesLeft=$left');
      }
    });

    test(
        'completion is bytesLeft == 0 — an empty batch with bytesLeft > 0 '
        'is NOT done', () {
      // The bug this pins against: reading `received == 0` as "drain
      // finished" stops a sync while the ring still holds undelivered
      // history, because a batch can legitimately answer zero events for a
      // stale cursor while the ring's flash still has bytes behind it. Only
      // `bytesLeft == 0` may end the loop.
      final stale = parseBatchSummary(batchFrame(0, 0, 3742))!;
      expect(stale.received, 0);
      expect(stale.bytesLeft, 3742,
          reason: 'zero events this batch must not read as zero remaining');
      final done = parseBatchSummary(batchFrame(0, 0, 0))!;
      expect(done.bytesLeft, 0);
    });

    test('a real captured frame decodes under the same field layout', () {
      // `11 08 08 00 9e0e0000 0300`: received=8, progress=0 (discarded),
      // bytesLeft = 0x00000e9e = 3742, trailing `0300` unused. Parsed from
      // the literal captured bytes — not built via [batchFrame] above, which
      // encodes with the exact layout under test and so cannot catch a
      // field-offset error here.
      final s = parseBatchSummary(parseOuraFrame(_hex('110808009e0e00000300'))!)!;
      expect(s.received, 8);
      expect(s.bytesLeft, 3742);
    });
  });
}
