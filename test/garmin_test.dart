import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('COBS', () {
    test('round-trips data with no zero bytes', () {
      final data = [1, 2, 3, 255, 254, 10];
      final framed = garminCobsEncode(data);
      expect(framed.first, 0x00);
      expect(framed.last, 0x00);
      expect(garminCobsDecode(framed), orderedEquals(data));
    });

    test('round-trips data full of zero bytes', () {
      final data = [0, 0, 0, 1, 0, 2, 0];
      expect(garminCobsDecode(garminCobsEncode(data)), orderedEquals(data));
    });

    test('round-trips a run of 254+ non-zero bytes', () {
      final data = List<int>.generate(300, (i) => (i % 255) + 1);
      expect(garminCobsDecode(garminCobsEncode(data)), orderedEquals(data));
    });

    test('round-trips empty data', () {
      expect(garminCobsDecode(garminCobsEncode(const [])), isEmpty);
    });

    test('reassembler splits a frame delivered across two writes', () {
      final data = [10, 20, 0, 30];
      final framed = garminCobsEncode(data);
      final r = GarminCobsReassembler();
      final mid = framed.length ~/ 2;
      expect(r.feed(framed.sublist(0, mid)), isEmpty);
      final out = r.feed(framed.sublist(mid));
      expect(out, hasLength(1));
      expect(out.single, orderedEquals(data));
    });

    test('reassembler recovers two frames coalesced into one delivery', () {
      final a = garminCobsEncode([1, 2]);
      final b = garminCobsEncode([3, 4, 5]);
      final r = GarminCobsReassembler();
      final out = r.feed([...a, ...b]);
      expect(out, hasLength(2));
      expect(out[0], orderedEquals([1, 2]));
      expect(out[1], orderedEquals([3, 4, 5]));
    });
  });

  group('CRC16', () {
    test('the empty message is zero', () {
      expect(garminCrc16(const []), 0);
    });

    test('changes for a single differing byte', () {
      final a = garminCrc16([1, 2, 3, 4]);
      final b = garminCrc16([1, 2, 3, 5]);
      expect(a, isNot(b));
    });
  });

  group('GFDI frame', () {
    test('builds and parses a frame, and rejects a corrupted CRC', () {
      final payload = [0xaa, 0xbb, 0xcc];
      final frame = garminBuildGfdiFrame(5024, payload);
      final parsed = garminParseGfdiFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.type, 5024);
      expect(parsed.payload, orderedEquals(payload));

      final corrupted = Uint8List.fromList(frame);
      corrupted[corrupted.length - 1] ^= 0xff;
      expect(garminParseGfdiFrame(corrupted), isNull);
    });

    test('rejects a frame whose declared size disagrees with its length', () {
      final frame = garminBuildGfdiFrame(5000, const [1, 2]);
      expect(garminParseGfdiFrame(frame.sublist(0, frame.length - 1)), isNull);
    });

    test('status ack round-trips the referenced message type', () {
      final ack = garminBuildStatusAck(5024);
      final parsed = garminParseGfdiFrame(ack)!;
      final status = garminParseStatusAck(parsed);
      expect(status, isNotNull);
      expect(status!.refMsgType, 5024);
      expect(status.ok, isTrue);
    });

    test('time response carries the Garmin-epoch timestamp and UTC offset',
        () {
      final nowUnix = 1735689600; // 2025-01-01T00:00:00Z
      final frame = garminBuildTimeResponse(
          nowUnixSeconds: nowUnix, utcOffsetSeconds: 3600);
      final parsed = garminParseGfdiFrame(frame)!;
      expect(parsed.type, kGarminMsgResponse);
      final view = ByteData.sublistView(parsed.payload);
      expect(view.getUint16(0, Endian.little), kGarminMsgCurrentTimeRequest);
      expect(view.getUint32(7, Endian.little),
          nowUnix - kGarminEpochOffset);
      expect(view.getInt32(11, Endian.little), 3600);
    });
  });

  group('MLR', () {
    test('close-all and register-ml requests are 12 bytes', () {
      expect(garminCloseAllRequest(), hasLength(12));
      expect(garminRegisterMlRequest(kGarminServiceGfdi), hasLength(12));
    });

    test('a flagged data frame reports its handle', () {
      final decoded = garminDecodeMlr([0x80 | (2 << 4), 1, 2, 3]);
      expect(decoded, isA<GarminMlrData>());
      expect((decoded as GarminMlrData).handle, 2);
    });

    test('CLOSE_ALL_RESP decodes to the close-all ack', () {
      expect(garminDecodeMlr(const [0x00, 0x06]), isA<GarminCloseAllAck>());
    });

    test('REGISTER_ML_RESP decodes service, status and handle', () {
      final resp = garminDecodeMlr(_registerMlResp(
        serviceCode: kGarminServiceGfdi,
        status: 0,
        handle: 3,
      ));
      expect(resp, isA<GarminRegisterMlResponse>());
      final r = resp as GarminRegisterMlResponse;
      expect(r.service, kGarminServiceGfdi);
      expect(r.accepted, isTrue);
      expect(r.handle, 3);
    });
  });

  group('device information', () {
    test('parses the fixed header and three Pascal strings', () {
      final payload = BytesBuilder()
        ..add(_u16(2))
        ..add(_u16(3122))
        ..add(_u32(123456))
        ..add(_u16(1920)) // firmware 19.20
        ..add(_u16(200))
        ..addByte(5)
        ..add('watch'.codeUnits)
        ..addByte(7)
        ..add('fenix 7'.codeUnits)
        ..addByte(6)
        ..add('fenix7'.codeUnits);
      final frame =
          garminBuildGfdiFrame(kGarminMsgDeviceInformation, payload.toBytes());
      final parsed = garminParseGfdiFrame(frame)!;
      final info = garminParseDeviceInformation(parsed);
      expect(info, isNotNull);
      expect(info!.productNumber, 3122);
      expect(info.unitNumber, 123456);
      expect(info.firmware, '19.20');
      expect(info.bluetoothName, 'watch');
      expect(info.deviceName, 'fenix 7');
      expect(info.deviceModel, 'fenix7');
    });
  });

  group('battery protobuf', () {
    test('the request marks the empty sub-message present', () {
      final req = garminBatteryRequestProto();
      // field 8 (device_status_service), wire type 2 (length-delimited):
      // tag byte (8<<3|2)=66, then its own length, then field 2's tag/length.
      expect(req, orderedEquals([66, 2, 18, 0]));
    });

    test('parses status and level out of a Smart response', () {
      // Smart{ device_status_service{ remote_device_battery_status_response{
      //   status=1, current_battery_level=73 } } }
      final inner = [8, 1, 16, 73]; // field1 varint(1), field2 varint(73)
      final service = [26, inner.length, ...inner]; // field3 len-delim
      final smart = [66, service.length, ...service]; // field8 len-delim
      final battery = garminParseBatteryResponseProto(
          Uint8List.fromList(smart));
      expect(battery, isNotNull);
      expect(battery!.status, 1);
      expect(battery.level, 73);
    });

    test('a response with no battery field parses to null', () {
      expect(garminParseBatteryResponseProto(Uint8List.fromList([])), isNull);
    });
  });

  group('protobuf request/response GFDI envelope', () {
    test('single-frame round trip is complete', () {
      final proto = garminBatteryRequestProto();
      final frame = garminBuildProtobufRequest(requestId: 7, protoBytes: proto);
      final gfdi = garminParseGfdiFrame(frame)!;
      final pf = garminParseProtobufFrame(gfdi)!;
      expect(pf.requestId, 7);
      expect(pf.isComplete, isTrue);
      expect(pf.protoBytes, orderedEquals(proto));
    });
  });
}

List<int> _u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little))
    .buffer
    .asUint8List();
List<int> _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little))
    .buffer
    .asUint8List();

List<int> _registerMlResp({
  required int serviceCode,
  required int status,
  required int handle,
}) {
  final out = List<int>.filled(14, 0);
  out[0] = 0x00;
  out[1] = 0x01;
  final svc = ByteData(2)..setInt16(0, serviceCode, Endian.little);
  out[10] = svc.getUint8(0);
  out[11] = svc.getUint8(1);
  out[12] = status;
  out[13] = handle;
  return out;
}
