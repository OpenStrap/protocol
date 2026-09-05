// The R11M/R10M ring wire format, checked against the one real example frame
// available: a model-query request, `02 03 08 00 47 50 ef 20`. Everything
// else here follows from that frame's own header shape plus the exact
// command/ack byte sequences the source material states directly — nothing
// is checked against a second independent capture, because there is no
// second one to check against (ASSUMPTIONS R6, nobody owns this ring).

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

void main() {
  group('framing', () {
    test('the model-query example decodes exactly, CRC included', () {
      final f = parseRing11mFrame(_hex('020308004750ef20'));
      expect(f, isNotNull);
      expect(f!.group, 0x02);
      expect(f.command, 0x03);
      expect(f.payload, [0x47, 0x50]);
    });

    test('the builder reproduces the example frame byte-for-byte', () {
      final built = buildRing11mFrame(0x02, 0x03, [0x47, 0x50]);
      expect(built, _hex('020308004750ef20'));
    });

    test('a bad CRC is refused, not silently accepted', () {
      final bytes = _hex('020308004750ef21'); // last byte flipped
      expect(parseRing11mFrame(bytes), isNull);
    });

    test('a declared length longer than the delivered bytes is refused', () {
      final bytes = _hex('02030a004750ef20'); // len says 10, only 8 delivered
      expect(parseRing11mFrame(bytes), isNull);
    });

    test('round trip through every payload width, CRC verified', () {
      for (final len in [0, 1, 2, 16, 240]) {
        final payload = List<int>.generate(len, (i) => i & 0xff);
        final built = buildRing11mFrame(0x05, 0x11, payload);
        final f = parseRing11mFrame(built);
        expect(f!.payload, payload, reason: 'width $len');
      }
    });
  });

  group('device info', () {
    test('model reply is the ASCII string, unmodified', () {
      final f = Ring11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdModelQuery,
          Uint8List.fromList('R11M'.codeUnits));
      expect(parseRing11mModel(f), 'R11M');
    });

    test('a non-ASCII model reply is refused, not mangled', () {
      final f = Ring11mFrame(
          kRing11mGroupDeviceInfo, kRing11mCmdModelQuery, Uint8List.fromList([0xff, 0x00]));
      expect(parseRing11mModel(f), isNull);
    });

    test('battery percent at offset 0, bounded 0-100', () {
      final ok = Ring11mFrame(
          kRing11mGroupDeviceInfo, kRing11mCmdBatteryQuery, Uint8List.fromList([72]));
      expect(parseRing11mBattery(ok), 72);
      final bad = Ring11mFrame(
          kRing11mGroupDeviceInfo, kRing11mCmdBatteryQuery, Uint8List.fromList([200]));
      expect(parseRing11mBattery(bad), isNull);
    });

    test('capability reply is handed back raw, never bit-decoded', () {
      final f = Ring11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdCapabilityQuery,
          Uint8List.fromList([0x01, 0x02]));
      expect(parseRing11mCapabilitiesRaw(f), [0x01, 0x02]);
    });

    test('model query reproduces the verified example frame byte-for-byte', () {
      expect(ring11mCmdModelQuery(), _hex('020308004750ef20'));
    });
  });

  group('setting', () {
    test('set-time packs the seven local fields plus weekday, in order', () {
      final t = DateTime(2026, 9, 5, 14, 30, 12); // a Saturday
      final f = parseRing11mFrame(ring11mCmdSetTime(t))!;
      expect(f.payload.length, 8);
      expect(f.payload[0] | (f.payload[1] << 8), 2026);
      expect(f.payload.sublist(2), [9, 5, 14, 30, 12, t.weekday]);
    });

    test('the automatic-toggle interval snaps to 30 or 60, nothing between', () {
      final low = parseRing11mFrame(
          ring11mCmdAutoToggle(kRing11mCmdAutoHrToggle, true, intervalMinutes: 10))!;
      expect(low.payload, [0x01, 30]);
      final high = parseRing11mFrame(
          ring11mCmdAutoToggle(kRing11mCmdAutoSpo2Toggle, false, intervalMinutes: 45))!;
      expect(high.payload, [0x00, 60]);
    });

    test('the automatic-toggle command selector is checked, not passed through', () {
      expect(() => ring11mCmdAutoToggle(kRing11mCmdSetTime, true),
          throwsArgumentError);
    });
  });

  group('app control', () {
    test('manual measurement payload is [start-flag, kind]', () {
      final f = parseRing11mFrame(
          ring11mCmdManualMeasurement(true, kRing11mMeasureSpo2))!;
      expect(f.payload, [0x01, kRing11mMeasureSpo2]);
    });

    test('an unrecognised manual-measurement kind is refused, not sent', () {
      expect(() => ring11mCmdManualMeasurement(true, 0x7f), throwsArgumentError);
    });

    test('find-device and live-totals both carry an empty payload', () {
      expect(parseRing11mFrame(ring11mCmdFindDevice())!.payload, isEmpty);
      expect(parseRing11mFrame(ring11mCmdLiveActivityTotals())!.payload, isEmpty);
    });
  });

  group('health/history transfer', () {
    test('the terminator carries the packet count and the trailing CRC', () {
      final f = Ring11mFrame(kRing11mGroupHealthHistory, kRing11mCmdHistoryTerminator,
          Uint8List.fromList([0x05, 0x00, 0xaa, 0xbb, 0x34, 0x12]));
      final t = parseRing11mHistoryTerminator(f)!;
      expect(t.packetCount, 5);
      expect(t.crc16, 0x1234);
    });

    test('a terminator too short to hold both fields is refused', () {
      final f = Ring11mFrame(
          kRing11mGroupHealthHistory, kRing11mCmdHistoryTerminator, Uint8List.fromList([0, 0]));
      expect(parseRing11mHistoryTerminator(f), isNull);
    });

    test('the block CRC is the same construction the outer frame uses', () {
      final data = [1, 2, 3, 4, 5];
      // Same primitive the framing group already pins against the example
      // frame — checked here by reproducing it over a whole frame's
      // pre-CRC bytes and confirming it against the known-good example.
      final wholeFrameCrc = ring11mHistoryCrc(_hex('02030800' '4750'));
      expect(wholeFrameCrc, 0x20ef);
      expect(ring11mHistoryCrc(data), isNot(0)); // sanity: it moves
    });

    test('ack is exactly 05 80 00, nack is exactly 05 80 04', () {
      expect(buildRing11mHistoryAck(true), [0x05, 0x80, 0x00]);
      expect(buildRing11mHistoryAck(false), [0x05, 0x80, 0x04]);
    });

    test('ring11mHistoryBlockCrcOk is the paired check for a parsed terminator',
        () {
      const data = [1, 2, 3, 4, 5, 6, 7, 8];
      final crc = ring11mHistoryCrc(data);
      final good = parseRing11mHistoryTerminator(Ring11mFrame(
          kRing11mGroupHealthHistory,
          kRing11mCmdHistoryTerminator,
          Uint8List.fromList([0x01, 0x00, crc & 0xff, (crc >> 8) & 0xff])))!;
      expect(ring11mHistoryBlockCrcOk(data, good), isTrue);
      final bad = parseRing11mHistoryTerminator(Ring11mFrame(
          kRing11mGroupHealthHistory,
          kRing11mCmdHistoryTerminator,
          Uint8List.fromList([0x01, 0x00, 0xde, 0xad])))!;
      expect(ring11mHistoryBlockCrcOk(data, bad), isFalse);
    });
  });

  group('framing limits', () {
    test('a payload past the u16 length field is refused, not truncated', () {
      expect(
          () => buildRing11mFrame(0x05, 0x01, List.filled(kRing11mMaxPayloadLen + 1, 0)),
          throwsArgumentError);
      // The ceiling itself still builds.
      expect(buildRing11mFrame(0x05, 0x01, List.filled(kRing11mMaxPayloadLen, 0)).length,
          0xffff);
    });
  });
}
