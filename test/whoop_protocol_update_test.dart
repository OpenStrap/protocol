import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WHOOP command builders', () {
    test('history result success uses cmd 0x17 + success byte + token', () {
      final frame = parseFrame(
        buildHistoryResultOk(0x21, hexToBytes('1122334455667788')),
      )!;
      expect(frame.valid, isTrue);
      expect(
        frame.inner,
        [0x23, 0x21, 0x17, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
      );
    });

    test('history result failure uses cmd 0x17 + failure byte', () {
      final frame = parseFrame(buildHistoryResultFail(0x22))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [0x23, 0x22, 0x17, 0x00]);
    });

    test('enter high-frequency sync uses revision 2 + little-endian u16s', () {
      final frame = parseFrame(
        cmdEnterHighFreqSync(0x12, intervalSeconds: 300, durationSeconds: 900),
      )!;
      expect(frame.valid, isTrue);
      expect(
        frame.inner,
        [0x23, 0x12, 0x60, 0x02, 0x2c, 0x01, 0x84, 0x03],
      );
    });

    test('exit high-frequency sync is payloadless', () {
      final frame = parseFrame(cmdExitHighFreqSync(0x34))!;
      expect(frame.valid, isTrue);
      expect(frame.inner.sublist(0, 3), [0x23, 0x34, 0x61]);
    });

    test('select wrist writes revision 1 + laterality', () {
      final frame = parseFrame(cmdSelectWrist(0x07, WristSelection.left))!;
      expect(frame.valid, isTrue);
      expect(frame.inner.sublist(0, 5), [0x23, 0x07, 0x7b, 0x01, 0x02]);
    });

    test('modern hello uses opcode 0x91 with revision 1 payload', () {
      final frame = parseFrame(cmdGetHelloModern(0x01))!;
      expect(frame.valid, isTrue);
      expect(frame.inner, [0x23, 0x01, 0x91, 0x01]);
    });
  });

  group('WHOOP command response decode', () {
    test('0x54 body location/status decodes exact fields', () {
      final inner = hexToBytes('2401540107a005');
      final resp = parseCommandResponse(inner)!;
      final body =
          resp.decoded['body_location_status'] as BodyLocationStatusResponse;
      expect(resp.opcode, Cmd.getBodyLocationAndStatus);
      expect(body.revision, 1);
      expect(body.locationRaw, 7);
      expect(body.location, GarmentDeviceLocation.ankle);
      expect(body.confidence, 160);
      expect(body.status, 5);
    });

    test('0x97 battery pack info decodes identifier, name and type', () {
      final inner = hexToBytes(
        '240297'
        '0101'
        '112233445566'
        '50756666696e20426174746572790000'
        '0000'
        '0c'
        '07',
      );
      final resp = parseCommandResponse(inner)!;
      final pack = resp.decoded['battery_pack_info'] as BatteryPackInfoResponse;
      expect(resp.opcode, Cmd.getBatteryPackInfo);
      expect(pack.revision, 1);
      expect(pack.attached, isTrue);
      expect(pack.identifier, '11:22:33:44:55:66');
      expect(pack.name, 'Puffin Battery');
      expect(pack.batteryPackTypeRaw, 12);
      expect(pack.batteryPackType, BatteryPackType.puffin);
      expect(pack.statusRaw, 7);
    });

    test('0x07 version info is surfaced honestly as raw payload', () {
      final inner = hexToBytes('24010700112233445566778899aabbccddeeff0011');
      final resp = parseCommandResponse(inner)!;
      final info = resp.decoded['version_info'] as Map<String, dynamic>;
      expect(resp.opcode, Cmd.reportVersionInfo);
      expect(info['payload_len'], 18);
      expect(info['raw_hex'], '00112233445566778899aabbccddeeff0011');
    });

    test('0x7b select wrist response is modeled as an ack payload', () {
      final inner = hexToBytes('24037b0102');
      final resp = parseCommandResponse(inner)!;
      final ack = resp.decoded['select_wrist'] as SelectWristResponse;
      expect(resp.opcode, Cmd.selectWrist);
      expect(ack.revision, 1);
      expect(ack.payload, [0x01, 0x02]);
    });
  });

  group('WHOOP realtime HR revision 2', () {
    test('body location and off-body state decode from realtime HR v2', () {
      final body = hexToBytes(
        '0002'
        '78563412'
        'bc9a'
        '4f'
        '000000000000000000'
        '00'
        '02',
      );
      final parsed = parseRealtimeHrV2(body)!;
      expect(parsed.revision, 2);
      expect(parsed.tsEpoch, 0x12345678);
      expect(parsed.tsSubsecRaw, 0x9abc);
      expect(parsed.hrBpm, 0x4f);
      expect(parsed.isOffBody, isTrue);
      expect(parsed.locationRaw, 2);
      expect(parsed.location, GarmentDeviceLocation.bicep);
    });
  });

  group('WHOOP event decode', () {
    test('high-frequency prompt/enabled/disabled events are modeled', () {
      final prompt = parseEvent(hexToBytes('3001600001020304'))!;
      final enabled = parseEvent(hexToBytes('3001610001020304'))!;
      final disabled = parseEvent(hexToBytes('3001620001020304'))!;

      expect(prompt.eventId, EventId.highFreqSyncPrompt);
      expect(prompt.name, 'HIGH_FREQ_SYNC_PROMPT');
      expect(prompt.decoded['high_freq_sync'], 'prompt');

      expect(enabled.eventId, EventId.highFreqSyncEnabled);
      expect(enabled.name, 'HIGH_FREQ_SYNC_ENABLED');
      expect(enabled.decoded['high_freq_sync'], 'enabled');

      expect(disabled.eventId, EventId.highFreqSyncDisabled);
      expect(disabled.name, 'HIGH_FREQ_SYNC_DISABLED');
      expect(disabled.decoded['high_freq_sync'], 'disabled');
    });
  });

  group('WHOOP metadata decode', () {
    test('history end exposes expected packet count and ack token', () {
      final m = parseMetadata(
        hexToBytes('3100020000000000002a0000001122334455667788'),
      )!;
      expect(m.sub, SyncMeta.historyEnd);
      expect(m.expectedPacketCount, 42);
      expect(m.token, hexToBytes('1122334455667788'));
    });
  });
}
