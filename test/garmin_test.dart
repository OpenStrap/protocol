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

    test('reassembler skips stray delimiters between frames', () {
      final a = garminCobsEncode([1, 2, 3]);
      final b = garminCobsEncode([4, 0, 5]);
      for (final stray in [
        [0],
        [0, 0, 0],
      ]) {
        expect(GarminCobsReassembler().feed([...a, ...stray, ...b]),
            [orderedEquals([1, 2, 3]), orderedEquals([4, 0, 5])]);
        final r = GarminCobsReassembler();
        expect(r.feed([...a, ...stray]), [orderedEquals([1, 2, 3])]);
        expect(r.feed(b), [orderedEquals([4, 0, 5])]);
      }
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
      final unknown = garminParseGfdiFrame(
          garminBuildStatusAck(5099, status: kGarminStatusUnknown))!;
      expect(garminParseStatusAck(unknown)!.status, 2);
    });

    test('compact-form frames reach every parser', () {
      int compact(int type, int txn) => 0x8000 | (txn << 8) | (type - 5000);
      GarminGfdiFrame f(int type, List<int> payload) =>
          garminParseGfdiFrame(garminBuildGfdiFrame(compact(type, 3), payload))!;

      final time = garminBuildTimeResponse(
          f(kGarminMsgCurrentTimeRequest, [1, 0, 0, 0]),
          nowUnixSeconds: 1735689600,
          utcOffsetSeconds: 0)!;
      expect(time.sublist(2, 4), [0x00, 0x83],
          reason: 'the transaction id is echoed');
      expect(
          garminParseDeviceInformation(
              f(kGarminMsgDeviceInformation, List.filled(12, 0))),
          isNotNull);
      expect(garminParseSystemEvent(f(kGarminMsgSystemEvent, [8, 0])), (8, 0));
      final pb = garminParseGfdiFrame(
          garminBuildProtobufRequest(requestId: 1, protoBytes: const []))!;
      final pf = garminParseProtobufFrame(f(kGarminMsgProtobufResponse, pb.payload));
      expect(pf?.messageType, kGarminMsgProtobufResponse);
      expect(garminParseStatusAck(f(kGarminMsgResponse, [0xa0, 0x13, 0])),
          isNotNull);
    });

    test('protobuf ack carries request id, offset and chunk status', () {
      final req = garminParseGfdiFrame(garminBuildGfdiFrame(
          kGarminMsgProtobufResponse,
          garminParseGfdiFrame(garminBuildProtobufRequest(
                  requestId: 0x0102, protoBytes: const [1]))!
              .payload))!;
      final ack = garminParseGfdiFrame(
          garminBuildProtobufAck(req, garminParseProtobufFrame(req)!))!;
      expect(ack.type, kGarminMsgResponse);
      expect(ack.payload, [0xb4, 0x13, 0, 0x02, 0x01, 0, 0, 0, 0, 0, 0]);
    });

    test('system event frame', () {
      final f = garminParseGfdiFrame(
          garminBuildSystemEvent(kGarminEventHandshakeComplete))!;
      expect(f.type, kGarminMsgSystemEvent);
      expect(f.payload, [8, 0]);
    });

    test('time response carries the Garmin-epoch timestamp and UTC offset',
        () {
      final nowUnix = 1735689600; // 2025-01-01T00:00:00Z
      final request = garminParseGfdiFrame(garminBuildGfdiFrame(
          kGarminMsgCurrentTimeRequest, [0x2a, 0x01, 0x00, 0x00]))!;
      final frame = garminBuildTimeResponse(request,
          nowUnixSeconds: nowUnix, utcOffsetSeconds: 3600)!;
      final parsed = garminParseGfdiFrame(frame)!;
      expect(parsed.type, kGarminMsgResponse);
      final view = ByteData.sublistView(parsed.payload);
      expect(view.getUint16(0, Endian.little), kGarminMsgCurrentTimeRequest);
      expect(view.getUint32(3, Endian.little), 0x012a,
          reason: 'reference_id must echo the request');
      expect(view.getUint32(7, Endian.little),
          nowUnix - kGarminEpochOffset);
      expect(view.getInt32(11, Endian.little), 3600);
    });

    test('time response abstains without a request id to echo', () {
      final short = garminParseGfdiFrame(
          garminBuildGfdiFrame(kGarminMsgCurrentTimeRequest, [1, 2]))!;
      expect(
          garminBuildTimeResponse(short,
              nowUnixSeconds: 1735689600, utcOffsetSeconds: 0),
          isNull);
    });
  });

  group('MLR', () {
    test('close-all is 12 bytes on the wire, register-ml 13', () {
      expect(garminEncodeTx(0, garminCloseAllRequest()), hasLength(12));
      expect(garminEncodeTx(0, garminRegisterMlRequest(kGarminServiceGfdi)),
          hasLength(13));
    });

    test('an MLR (bit 7) frame is not decoded as COBS data', () {
      expect(garminDecodeMlr([0x80 | (2 << 4), 1, 2, 3]), isNull);
    });

    test('a bare non-zero handle byte is a data frame on that handle', () {
      final decoded = garminDecodeMlr(const [0x01, 0x00, 0x05, 0x01]);
      expect(decoded, isA<GarminMlrData>());
      expect((decoded as GarminMlrData).handle, 1);
      expect(decoded.payload, [0x00, 0x05, 0x01]);
      // above the 3-bit flagged range too
      expect((garminDecodeMlr(const [0x0c, 0x01]) as GarminMlrData).handle,
          0x0c);
      expect(garminDecodeMlr(const [0x03]), isNull);
    });

    test('close-all puts the client id right after the type', () {
      final v = ByteData.sublistView(garminCloseAllRequest());
      expect(v.getUint8(0), 0x05);
      expect(v.getInt64(1, Endian.little), 2);
      expect(v.getUint16(9, Endian.little), 0);
      // same offset as register-ml
      expect(ByteData.sublistView(garminRegisterMlRequest(kGarminServiceGfdi))
          .getInt64(1, Endian.little), 2);
    });

    test('CLOSE_ALL_RESP decodes to the close-all ack', () {
      expect(garminDecodeMlr(_control(0x06, [0, 0, 0])),
          isA<GarminCloseAllAck>());
      expect(garminDecodeMlr(const [0x00, 0x06]), isNull,
          reason: 'every control frame is at least 13 bytes');
    });

    test("another client's answers are not ours", () {
      expect(garminDecodeMlr(_control(0x06, [0, 0, 0], clientId: 9)),
          isA<GarminMlrControlOther>());
      final reg = _registerMlResp(
          serviceCode: kGarminServiceGfdi, status: 0, handle: 3)
        ..[2] = 9;
      expect(garminDecodeMlr(reg), isA<GarminMlrControlOther>());
    });

    test('HANDLE_CLOSED and INVALID_HANDLE name the handle that is gone', () {
      final closed = garminDecodeMlr(_control(0x03, [0, 0, 5, 0]));
      expect((closed as GarminHandleClosed).handle, 5);
      expect(garminDecodeMlr(_control(0x03, [0, 0, 5, 0], clientId: 9)),
          isA<GarminMlrControlOther>());
      final invalid = garminDecodeMlr(_control(0x04, [0, 0, 6], clientId: 9));
      expect((invalid as GarminHandleClosed).handle, 6);
    });

    test('a 13-byte refusal decodes; ALREADY_IN_USE names another char', () {
      final refused =
          garminDecodeMlr(_control(0x01, [kGarminServiceGfdi, 0, 1]));
      expect((refused as GarminRegisterMlResponse).status, 1);
      final pending = garminDecodeMlr(
          _control(0x01, [kGarminServiceGfdi, 0, kGarminRegisterPendingAuth]));
      expect((pending as GarminRegisterMlResponse).accepted, isFalse);
      final moved = garminDecodeMlr(_control(0x01,
          [kGarminServiceGfdi, 0, kGarminRegisterAlreadyInUse, 0x11, 0x28]));
      expect((moved as GarminRegisterMlResponse).alternateChar, 0x2811);
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

/// A control frame `0 | type | client id | rest`, our client id by default.
List<int> _control(int type, List<int> rest, {int clientId = 2}) => [
      0x00,
      type,
      ...(ByteData(8)..setInt64(0, clientId, Endian.little))
          .buffer
          .asUint8List(),
      ...rest,
    ];

List<int> _registerMlResp({
  required int serviceCode,
  required int status,
  required int handle,
}) {
  final out = List<int>.filled(14, 0);
  out[0] = 0x00;
  out[1] = 0x01;
  out[2] = 2; // client id
  final svc = ByteData(2)..setInt16(0, serviceCode, Endian.little);
  out[10] = svc.getUint8(0);
  out[11] = svc.getUint8(1);
  out[12] = status;
  out[13] = handle;
  return out;
}
