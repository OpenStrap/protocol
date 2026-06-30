import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WHOOP command builders', () {
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
}
