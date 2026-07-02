// Framing / CRC / ACK / INIT byte-exactness — ported from the edge protocol_test.dart.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('framing + CRC (INIT byte-exactness)', () {
    // HCI-snoop verbatim. Matching them validates buildFrame, crc8, crc32.
    const expected = [
      'aa0800a823002300ada86a2d',
      'aa0800a823014c00f2b5cdce',
      'aa0800a823022200824df537',
      'aa0800a823034301c54dd63d',
      'aa0800a823041600c7c25288',
    ];
    test('5-packet INIT regenerates byte-for-byte', () {
      for (int i = 0; i < expected.length; i++) {
        expect(_hex(initPackets[i]), expected[i], reason: 'INIT seq$i');
      }
    });

    test('round-trip: parseFrame(buildCommand(...)) is valid', () {
      final raw = buildCommand(0, Cmd.getHelloHarvard, const [0x00]);
      final f = parseFrame(raw);
      expect(f, isNotNull);
      expect(f!.crc8Ok, isTrue);
      expect(f.crc32Ok, isTrue);
      expect(f.packetType, PacketType.command);
      expect(f.opcode, Cmd.getHelloHarvard);
    });
  });

  group('SET_ALARM (cmdSetAlarm)', () {
    test('round-trip: valid frame, CRCs ok, opcode 0x42, epoch decodes back', () {
      const epoch = 1735689600; // 2025-01-01T00:00:00Z, a plausible alarm time
      const seq = 9;
      final raw = cmdSetAlarm(seq, epoch);
      final f = parseFrame(raw);
      expect(f, isNotNull);
      expect(f!.crc8Ok, isTrue);
      expect(f.crc32Ok, isTrue);
      expect(f.packetType, PacketType.command);
      expect(f.opcode, Cmd.setAlarmTime);
      expect(f.inner[1], seq);
      // payload starts at inner[3]: u32 epoch LE, then u32 zero pad.
      final bd =
          f.inner.buffer.asByteData(f.inner.offsetInBytes, f.inner.length);
      expect(bd.getUint32(3, Endian.little), epoch);
      expect(bd.getUint32(7, Endian.little), 0); // pad
    });

    test('SET_ALARM is NOT in dangerousCmds (normal user action)', () {
      expect(dangerousCmds.contains(Cmd.setAlarmTime), isFalse);
    });
  });

  group('batch ACK (the fragile breaking point)', () {
    test('ACK has the exact 12-byte inner shape [0x23][seq][0x17][0x01]+token', () {
      final token = List<int>.generate(8, (i) => i + 1);
      final raw = buildBatchAck(5, token);
      final f = parseFrame(raw)!;
      expect(f.crc8Ok && f.crc32Ok, isTrue);
      expect(f.inner.sublist(0, 4),
          [PacketType.command, 5, Cmd.historicalDataResult, revision1]);
      expect(f.inner.sublist(4, 12), token);
    });

    test('token must be 8 bytes', () {
      expect(() => buildBatchAck(5, [1, 2, 3]), throwsArgumentError);
    });

    test('parseMetadata extracts token inner[13:21] from a HistoryEnd marker', () {
      final inner = List<int>.filled(21, 0);
      inner[0] = PacketType.metadata;
      inner[1] = 0;
      inner[2] = SyncMeta.historyEnd;
      final token = [9, 8, 7, 6, 5, 4, 3, 2];
      for (int i = 0; i < 8; i++) {
        inner[13 + i] = token[i];
      }
      final m = parseMetadata(Uint8List.fromList(inner));
      expect(m, isNotNull);
      expect(m!.sub, SyncMeta.historyEnd);
      expect(m.token, token);
    });

    test('END→ACK round-trip: the 8-byte token is echoed VERBATIM (cursor fix)', () {
      // A full framed HISTORY_END (the band advances + trims its read cursor on the
      // ACK, but ONLY if the token we echo is the band's own continuation token).
      // metadata.data[10:18] == frame[17:25] == inner[13:21]. Build a real frame,
      // parse the token, ACK it, and assert the ACK carries those exact 8 bytes —
      // a verbatim echo. A wrong slice / mangled echo is the "Groundhog Day" cursor
      // bug (the band re-floods the same history on the next connect).
      final token = [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44];
      final metaInner = List<int>.filled(21, 0)
        ..[0] = PacketType.metadata
        ..[1] = 7 // arbitrary seq on the marker
        ..[2] = SyncMeta.historyEnd;
      for (int i = 0; i < 8; i++) {
        metaInner[13 + i] = token[i];
      }
      final endFrame = buildFrame(metaInner);
      // frame[17:25] is the metadata.data[10:18] slice the band acks verbatim.
      expect(endFrame.sublist(17, 25), token);

      final parsed = parseFrame(endFrame)!;
      final m = parseMetadata(parsed.inner)!;
      expect(m.token, token);

      final ack = buildBatchAck(5, m.token!);
      final af = parseFrame(ack)!;
      expect(af.crc8Ok && af.crc32Ok, isTrue);
      // [0x23][seq=5][0x17][0x01] + the verbatim token.
      expect(af.inner.sublist(0, 4),
          [PacketType.command, 5, Cmd.historicalDataResult, revision1]);
      expect(af.inner.sublist(4, 12), token);
    });
  });

  group('FrameReassembler (length-based, never reset on 0xAA)', () {
    test('carves multiple frames from a single chunk', () {
      final a = buildCommand(0, Cmd.getHelloHarvard, const [0x00]);
      final b = buildBatchAck(1, List<int>.generate(8, (i) => 0xAA)); // token full of SOF
      final stream = <int>[...a, ...b];
      final re = FrameReassembler();
      final frames = re.feed(stream);
      expect(frames.length, 2);
      expect(frames.every((f) => f.valid), isTrue,
          reason: '0xAA-laden payload must not break length-based reassembly');
    });

    test('reassembles across split BLE notification boundaries', () {
      final a = buildCommand(2, Cmd.getDataRange, const [0x00]);
      final re = FrameReassembler();
      final first = re.feed(a.sublist(0, 3));
      expect(first, isEmpty);
      final rest = re.feed(a.sublist(3));
      expect(rest.length, 1);
      expect(rest.first.valid, isTrue);
    });
  });
}
