// Garmin GFDI v2 — the wire format spoken over the Multi-Link BLE service
// (base UUID 6A4Exxxx-667B-11E3-949A-0800200C9A66). Bytes only: no BLE, no
// Flutter, no database.
//
// NOTHING HERE HAS MET HARDWARE. Ships EXPERIMENTAL: this file decodes only
// the device-info push, a battery round trip, and the plumbing (ack, time
// answer) a session is documented to need to stay open. No physiological
// signal is decoded or requested.
//
// THREE LAYERS, each with its own framing:
//
//  1. Multi-Link (ML/MLR) multiplexes several logical services over one
//     characteristic pair. The routing byte's bit 7 marks a watch-to-host MLR
//     data frame with the handle in bits 6:4; the host addresses a handle
//     with a bare byte. Handles are assigned per session by
//     CLOSE_ALL_REQ (evict whatever a previous session left registered) then
//     REGISTER_ML_REQ per service code (GFDI = 1).
//  2. COBS wraps the GFDI byte stream inside one ML handle — the public,
//     0x00-delimited algorithm, nothing band-specific about it.
//  3. A GFDI frame is `size:u16 | type:u16 | payload | crc16:u16`, all
//     little-endian; `size` counts the whole frame including itself and the
//     trailing CRC. The CRC is a 16-entry nibble-table algorithm, run low
//     nibble then high nibble of each byte, seeded at 0 and covering every
//     byte up to (not including) the CRC field itself.
//
// MESSAGE TYPES this file knows: DEVICE_INFORMATION (5024, an unprompted push
// once the GFDI handle opens — the only place the true model/firmware live,
// since the BLE advertised name is a marketing string), PROTOBUF_REQUEST/
// RESPONSE (5043/5044, wrapping a small hand-rolled protobuf reader — just
// enough fields to ask for and read `DeviceStatusService`'s battery status),
// CURRENT_TIME_REQUEST (5052, the watch asking for wall-clock time) and
// RESPONSE/STATUS (5000, both the plain ack every inbound GFDI message gets
// and the fuller time-answer shape). SYSTEM_EVENT (5030) is parsed for
// logging only.
//
// CUT ON PURPOSE: chunked protobuf reassembly (`data_offset > 0` is logged
// and abstained on, never guessed at), every OTHER numbered sub-service in
// the protobuf container, and the numbered real-time streaming services —
// none of that is touched by anything below.

import 'dart:typed_data';

// ═══════════════════════ Multi-Link (ML/MLR) ═══════════════════════
//
// GATT UUIDs are an edge-side (BLE) fact, not a protocol-bytes one — see
// `edge`'s `_registry.dart` for the service/characteristic UUIDs this format
// is carried over.

/// Service codes this file registers a handle for. Real watches expose many
/// more (six numbered real-time streams among them) — untouched this pass.
const int kGarminServiceGfdi = 1;
const int kGarminServiceRegistration = 4;

/// This host's client identifier on the control channel. Any value the watch
/// has not already bound to another client works; the exact number carries
/// no meaning back.
const int _kGarminClientId = 2;

const int _kMlrFlag = 0x80;
const int _kMlrHandleMask = 0x70;
const int _kMlrHandleShift = 4;

/// Widest handle a bare routing byte can address without setting the MLR
/// flag and being read back as a different handle.
const int kGarminMaxHandle = 0x7f;

const int _kReqRegisterMl = 0x00;
const int _kRespRegisterMl = 0x01;
const int _kReqCloseAll = 0x05;
const int _kRespCloseAll = 0x06;

/// Frame one ML control or data payload for the host-to-watch direction. The
/// host always addresses a handle with a bare byte — only the watch sets the
/// MLR flag on what it sends back.
Uint8List garminEncodeTx(int handle, List<int> payload) {
  if (handle < 0 || handle > kGarminMaxHandle) {
    throw ArgumentError.value(handle, 'handle', 'must be 0-$kGarminMaxHandle');
  }
  return Uint8List.fromList(<int>[handle, ...payload]);
}

/// One decoded notification on the ML control/data channel.
sealed class GarminMlrPacket {
  const GarminMlrPacket();
}

/// A data frame on an already-assigned handle — GFDI's COBS/GFDI bytes flow
/// through here after the routing byte is stripped by the caller.
class GarminMlrData extends GarminMlrPacket {
  final int handle;
  final Uint8List payload;
  const GarminMlrData(this.handle, this.payload);
}

/// CLOSE_ALL_RESP: every previously-registered handle is now void.
class GarminCloseAllAck extends GarminMlrPacket {
  const GarminCloseAllAck();
}

/// REGISTER_ML_RESP: the watch's answer to one handle request. `status == 0`
/// is acceptance; anything else is a refusal and [handle] is meaningless.
class GarminRegisterMlResponse extends GarminMlrPacket {
  final int service;
  final int status;
  final int handle;
  const GarminRegisterMlResponse(this.service, this.status, this.handle);
  bool get accepted => status == 0;
}

/// A control-channel frame this file has no specific decode for (an
/// unregistered request type, or a CLOSE_HANDLE reply this pass never
/// sends). Named so a caller can tell "recognised but uninteresting" apart
/// from [garminDecodeMlr] answering null for genuinely malformed input.
class GarminMlrControlOther extends GarminMlrPacket {
  final int type;
  const GarminMlrControlOther(this.type);
}

/// Route one raw notification. Null for input too short, or structurally not
/// one of the two shapes this protocol documents (a flagged watch-to-host
/// data frame, or a control frame with byte 0 clear) — everything else lands
/// in one of the [GarminMlrPacket] arms above.
GarminMlrPacket? garminDecodeMlr(List<int> data) {
  if (data.isEmpty) return null;
  if ((data[0] & _kMlrFlag) != 0) {
    final handle = (data[0] & _kMlrHandleMask) >> _kMlrHandleShift;
    return GarminMlrData(handle, Uint8List.fromList(data));
  }
  if (data[0] != 0) return null;
  if (data.length < 2) return null;
  final type = data[1];
  if (type == _kRespCloseAll) return const GarminCloseAllAck();
  if (type == _kRespRegisterMl) {
    if (data.length < 14) return null;
    final service = ByteData.sublistView(Uint8List.fromList(data), 10, 12)
        .getInt16(0, Endian.little);
    return GarminRegisterMlResponse(service, data[12], data[13]);
  }
  return GarminMlrControlOther(type);
}

/// CLOSE_ALL_REQ payload: type(u8) + reserved(u16=0) + client id(i64) +
/// reserved(u8=0). Wipes any handle a previous session left registered.
Uint8List garminCloseAllRequest() {
  final b = ByteData(12)
    ..setUint8(0, _kReqCloseAll)
    ..setUint16(1, 0, Endian.little)
    ..setInt64(3, _kGarminClientId, Endian.little)
    ..setUint8(11, 0);
  return b.buffer.asUint8List();
}

/// REGISTER_ML_REQ payload: type(u8) + client id(i64) + service code(i16) +
/// reserved(u8=0).
Uint8List garminRegisterMlRequest(int serviceCode) {
  final b = ByteData(12)
    ..setUint8(0, _kReqRegisterMl)
    ..setInt64(1, _kGarminClientId, Endian.little)
    ..setInt16(9, serviceCode, Endian.little)
    ..setUint8(11, 0);
  return b.buffer.asUint8List();
}

// ═══════════════════════════ COBS ═══════════════════════════
//
// The public, band-agnostic Consistent Overhead Byte Stuffing algorithm:
// 0x00 delimits a frame, and inside it every byte is stuffed so that no 0x00
// survives — each stuffing code is "how many bytes until the next 0x00 (or
// the end), plus one", with 0xFF meaning "254 bytes follow and the next code
// immediately follows with no implied zero" so a run of non-zero bytes
// longer than the codeable range does not need to invent one.

/// Encode [data] as one complete COBS frame, delimited on both ends.
Uint8List garminCobsEncode(List<int> data) {
  final out = BytesBuilder();
  out.addByte(0x00);
  var start = 0;
  var endedOnZero = false;
  while (start < data.length) {
    var zero = start;
    while (zero < data.length && data[zero] != 0x00) {
      zero++;
    }
    endedOnZero = zero < data.length;
    var runLen = zero - start;
    while (runLen >= 0xfe) {
      out.addByte(0xff);
      out.add(data.sublist(start, start + 0xfe));
      runLen -= 0xfe;
      start += 0xfe;
    }
    out.addByte(runLen + 1);
    out.add(data.sublist(start, start + runLen));
    start = zero + 1;
  }
  if (endedOnZero) out.addByte(0x01);
  out.addByte(0x00);
  return out.toBytes();
}

/// Decode one complete, 0x00-delimited COBS frame. Null for anything that is
/// not one — too short, or missing either delimiter — which is the reader's
/// signal to keep buffering rather than treat a partial arrival as garbage.
Uint8List? garminCobsDecode(List<int> framed) {
  if (framed.length < 2 || framed.first != 0x00 || framed.last != 0x00) {
    return null;
  }
  final body = framed.sublist(1, framed.length - 1);
  final out = BytesBuilder();
  var i = 0;
  while (i < body.length) {
    final code = body[i++];
    if (code == 0) break; // malformed stuffing; stop rather than misread
    final runLen = code - 1;
    if (i + runLen > body.length) return null;
    out.add(body.sublist(i, i + runLen));
    i += runLen;
    if (code != 0xff && i < body.length) out.addByte(0x00);
  }
  return out.toBytes();
}

/// Reassembles COBS frames out of BLE notifications, which may split one
/// frame across several writes or (rarely) coalesce more than one into a
/// single delivery.
///
/// ponytail: a byte-buffer scan per notification, not a streaming decoder —
/// this session's whole traffic is a handful of small frames, and a partial
/// or stale buffer resets on the next feed rather than growing without
/// bound.
class GarminCobsReassembler {
  final List<int> _buf = [];

  /// Feed newly-arrived bytes; returns every complete frame they produced
  /// (only ever more than one when the watch coalesced deliveries).
  List<Uint8List> feed(List<int> bytes) {
    _buf.addAll(bytes);
    final out = <Uint8List>[];
    while (true) {
      // A frame starts and ends on 0x00; find the first 0x00 after a leading
      // one to bound one candidate frame.
      if (_buf.isEmpty || _buf.first != 0x00) {
        final lead = _buf.indexOf(0x00);
        if (lead < 0) {
          _buf.clear();
          break;
        }
        _buf.removeRange(0, lead);
      }
      final end = _buf.indexOf(0x00, 1);
      if (end < 0) break; // frame not complete yet
      final candidate = _buf.sublist(0, end + 1);
      _buf.removeRange(0, end + 1);
      final decoded = garminCobsDecode(candidate);
      if (decoded != null) out.add(decoded);
    }
    return out;
  }
}

// ═══════════════════════════ CRC16 ═══════════════════════════
//
// A 16-entry nibble-table algorithm: each byte is folded in low nibble then
// high nibble. The same table Garmin's FIT file format documents for its own
// integrity check.
const List<int> _kCrcTable = <int>[
  0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401, //
  0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400,
];

/// Compute the CRC over [data], seeded at [seed] (0 for a fresh frame).
int garminCrc16(List<int> data, [int seed = 0]) {
  var crc = seed;
  for (final byte in data) {
    crc = ((crc >> 4) & 0x0fff) ^ _kCrcTable[crc & 0x0f] ^ _kCrcTable[byte & 0x0f];
    crc = ((crc >> 4) & 0x0fff) ^
        _kCrcTable[crc & 0x0f] ^
        _kCrcTable[(byte >> 4) & 0x0f];
  }
  return crc & 0xffff;
}

// ═══════════════════════════ GFDI frame ═══════════════════════════
//
// `size:u16 | type:u16 | payload | crc16:u16`, all little-endian. `size` is
// the WHOLE frame's byte count, itself and the CRC included; the CRC covers
// every byte from `size` up to (not including) itself.

const int kGarminMsgResponse = 5000;
const int kGarminMsgDeviceInformation = 5024;
const int kGarminMsgSystemEvent = 5030;
const int kGarminMsgProtobufRequest = 5043;
const int kGarminMsgProtobufResponse = 5044;
const int kGarminMsgCurrentTimeRequest = 5052;

/// One decoded GFDI frame: its message type and the payload after the
/// 4-byte header, with the CRC already verified.
class GarminGfdiFrame {
  final int type;
  final Uint8List payload;
  const GarminGfdiFrame(this.type, this.payload);
}

/// Build one GFDI frame of [type] carrying [payload].
Uint8List garminBuildGfdiFrame(int type, List<int> payload) {
  final size = 4 + payload.length + 2;
  final head = ByteData(4)
    ..setUint16(0, size, Endian.little)
    ..setUint16(2, type, Endian.little);
  final body = <int>[...head.buffer.asUint8List(), ...payload];
  final crc = garminCrc16(body);
  final crcBytes = ByteData(2)..setUint16(0, crc, Endian.little);
  return Uint8List.fromList(<int>[...body, ...crcBytes.buffer.asUint8List()]);
}

/// Parse one COBS-unwrapped GFDI frame. Null when it is too short, its
/// declared `size` disagrees with the bytes actually delivered, or the CRC
/// does not check out — a frame this file cannot trust is not one it acts on.
GarminGfdiFrame? garminParseGfdiFrame(List<int> frame) {
  if (frame.length < 6) return null;
  final bytes = Uint8List.fromList(frame);
  final view = ByteData.sublistView(bytes);
  final size = view.getUint16(0, Endian.little);
  if (size != bytes.length) return null;
  final type = view.getUint16(2, Endian.little);
  final body = bytes.sublist(0, size - 2);
  final declaredCrc = view.getUint16(size - 2, Endian.little);
  if (garminCrc16(body) != declaredCrc) return null;
  return GarminGfdiFrame(type, bytes.sublist(4, size - 2));
}

/// Build the plain ack every inbound GFDI message (other than a RESPONSE
/// itself) is documented to need: `ref_msg_type:u16 | status:i8(0)`, wrapped
/// as a RESPONSE (5000) frame.
Uint8List garminBuildStatusAck(int refMsgType) {
  final b = ByteData(3)
    ..setUint16(0, refMsgType, Endian.little)
    ..setInt8(2, 0);
  return garminBuildGfdiFrame(kGarminMsgResponse, b.buffer.asUint8List());
}

/// One decoded RESPONSE (5000) frame: which message it answers, and whether
/// that was accepted (`status == 0`).
class GarminStatusAck {
  final int refMsgType;
  final int status;
  const GarminStatusAck(this.refMsgType, this.status);
  bool get ok => status == 0;
}

GarminStatusAck? garminParseStatusAck(GarminGfdiFrame f) {
  if (f.type != kGarminMsgResponse || f.payload.length < 3) return null;
  final view = ByteData.sublistView(f.payload);
  return GarminStatusAck(
      view.getUint16(0, Endian.little), view.getInt8(2));
}

/// Seconds between the Unix epoch and Garmin's own epoch (1990-01-01
/// 00:00:00 UTC), which every Garmin timestamp field on this wire is counted
/// from.
const int kGarminEpochOffset = 631065600;

/// Build the full answer to CURRENT_TIME_REQUEST (5052): a RESPONSE (5000)
/// frame shaped as `ref_msg_type:u16(5052) | status:i8(0) | reference_id:u32(0)
/// | garmin_timestamp:u32 | utc_offset_sec:i32 | dst_end:i32(0) |
/// dst_start:i32(0)`. DST transitions are left at 0 — this pass states the
/// current UTC offset and nothing about a future change to it.
Uint8List garminBuildTimeResponse({
  required int nowUnixSeconds,
  required int utcOffsetSeconds,
}) {
  final b = ByteData(23)
    ..setUint16(0, kGarminMsgCurrentTimeRequest, Endian.little)
    ..setInt8(2, 0)
    ..setUint32(3, 0, Endian.little)
    ..setUint32(7, nowUnixSeconds - kGarminEpochOffset, Endian.little)
    ..setInt32(11, utcOffsetSeconds, Endian.little)
    ..setInt32(15, 0, Endian.little)
    ..setInt32(19, 0, Endian.little);
  return garminBuildGfdiFrame(kGarminMsgResponse, b.buffer.asUint8List());
}

/// The watch's self-description (5024): a fixed 12-byte header, then three
/// 1-byte-length-prefixed UTF-8 strings — bluetooth name, device name,
/// device model. Pushed unprompted once the GFDI handle opens; the only
/// place the true model and firmware live, since the BLE advertised name is
/// a marketing string.
class GarminDeviceInformation {
  final int protocolVersion;
  final int productNumber;
  final int unitNumber;
  final int softwareVersion;
  final int maxPacketSize;
  final String bluetoothName;
  final String deviceName;
  final String deviceModel;

  const GarminDeviceInformation({
    required this.protocolVersion,
    required this.productNumber,
    required this.unitNumber,
    required this.softwareVersion,
    required this.maxPacketSize,
    required this.bluetoothName,
    required this.deviceName,
    required this.deviceModel,
  });

  /// Formatted the way Garmin displays it (e.g. `19.20`).
  String get firmware =>
      '${softwareVersion ~/ 100}.${(softwareVersion % 100).toString().padLeft(2, '0')}';
}

(String, int) _readPascalString(Uint8List data, int offset) {
  if (offset >= data.length) return ('', offset);
  final len = data[offset];
  final start = offset + 1;
  final end = (start + len).clamp(0, data.length);
  return (String.fromCharCodes(data.sublist(start, end)), end);
}

GarminDeviceInformation? garminParseDeviceInformation(GarminGfdiFrame f) {
  if (f.type != kGarminMsgDeviceInformation || f.payload.length < 12) {
    return null;
  }
  final view = ByteData.sublistView(f.payload);
  final protocolVersion = view.getUint16(0, Endian.little);
  final productNumber = view.getUint16(2, Endian.little);
  final unitNumber = view.getUint32(4, Endian.little);
  final softwareVersion = view.getUint16(8, Endian.little);
  final maxPacketSize = view.getUint16(10, Endian.little);
  final btStep = _readPascalString(f.payload, 12);
  final devStep = _readPascalString(f.payload, btStep.$2);
  final modelStep = _readPascalString(f.payload, devStep.$2);
  final bt = btStep.$1, dev = devStep.$1, model = modelStep.$1;
  return GarminDeviceInformation(
    protocolVersion: protocolVersion,
    productNumber: productNumber,
    unitNumber: unitNumber,
    softwareVersion: softwareVersion,
    maxPacketSize: maxPacketSize,
    bluetoothName: bt,
    deviceName: dev,
    deviceModel: model,
  );
}

/// `(event_type, value)` out of a SYSTEM_EVENT (5030) frame — logged only,
/// never acted on this pass.
(int, int)? garminParseSystemEvent(GarminGfdiFrame f) {
  if (f.type != kGarminMsgSystemEvent || f.payload.isEmpty) return null;
  return (f.payload[0], f.payload.length > 1 ? f.payload[1] : 0);
}

// ══════════════════ PROTOBUF_REQUEST / PROTOBUF_RESPONSE ══════════════════
//
// Payload: `request_id:u16 | data_offset:u32 | total_length:u32 |
// proto_len:i32 | proto_bytes`. Garmin chunks a large protobuf across several
// frames; this file only ever sends and reads a single-frame message, so
// [GarminProtobufFrame.isComplete] is the whole of its chunking support — a
// chunked reply is surfaced, never reassembled.

class GarminProtobufFrame {
  final int messageType;
  final int requestId;
  final int dataOffset;
  final int totalLength;
  final Uint8List protoBytes;

  const GarminProtobufFrame({
    required this.messageType,
    required this.requestId,
    required this.dataOffset,
    required this.totalLength,
    required this.protoBytes,
  });

  bool get isComplete =>
      dataOffset == 0 && totalLength == protoBytes.length;
}

/// Build a PROTOBUF_REQUEST (5043) frame carrying [protoBytes] as a single,
/// unchunked message (`data_offset` 0, `total_length` its own length).
Uint8List garminBuildProtobufRequest({
  required int requestId,
  required List<int> protoBytes,
}) {
  final head = ByteData(14)
    ..setUint16(0, requestId, Endian.little)
    ..setUint32(2, 0, Endian.little)
    ..setUint32(6, protoBytes.length, Endian.little)
    ..setInt32(10, protoBytes.length, Endian.little);
  return garminBuildGfdiFrame(kGarminMsgProtobufRequest,
      <int>[...head.buffer.asUint8List(), ...protoBytes]);
}

/// Parse the protobuf envelope out of a PROTOBUF_REQUEST/RESPONSE frame.
GarminProtobufFrame? garminParseProtobufFrame(GarminGfdiFrame f) {
  if ((f.type != kGarminMsgProtobufRequest &&
          f.type != kGarminMsgProtobufResponse) ||
      f.payload.length < 14) {
    return null;
  }
  final view = ByteData.sublistView(f.payload);
  final requestId = view.getUint16(0, Endian.little);
  final dataOffset = view.getUint32(2, Endian.little);
  final totalLength = view.getUint32(6, Endian.little);
  final protoLen = view.getInt32(10, Endian.little);
  if (protoLen < 0 || 14 + protoLen > f.payload.length) return null;
  return GarminProtobufFrame(
    messageType: f.type,
    requestId: requestId,
    dataOffset: dataOffset,
    totalLength: totalLength,
    protoBytes: f.payload.sublist(14, 14 + protoLen),
  );
}

// ═══════════════ minimal protobuf wire (varint + length-delimited) ═══════════════
//
// Purpose-built for the four fields this pass touches — nowhere near a
// general decoder, and not meant to become one. `Smart` (the outer envelope)
// nests one field per numbered sub-service; the path used here is
// `Smart.device_status_service` (field 8) ->
// `DeviceStatusService.remote_device_battery_status_request` (field 2, sent
// empty) / `...response` (field 3, read back) ->
// `RemoteDeviceBatteryStatusResponse.status` (field 1, varint) /
// `.current_battery_level` (field 2, varint, plain `int32` not zigzag).

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (true) {
    final b = v & 0x7f;
    v >>= 7;
    if (v == 0) {
      out.addByte(b);
      return;
    }
    out.addByte(b | 0x80);
  }
}

/// Wrap [inner] as field [number]'s length-delimited value (wire type 2).
Uint8List _protoLenDelim(int number, List<int> inner) {
  final out = BytesBuilder();
  _writeVarint(out, (number << 3) | 2);
  _writeVarint(out, inner.length);
  out.add(inner);
  return out.toBytes();
}

/// One field read off the wire: its number, wire type, and either a decoded
/// varint or the raw bytes of a length-delimited value.
class _ProtoField {
  final int number;
  final int wireType;
  final int? varint;
  final Uint8List? bytes;
  const _ProtoField(this.number, this.wireType, {this.varint, this.bytes});
}

/// Walk one message's top-level fields. Skips fixed32/fixed64 payloads it
/// does not need to read (advances past them correctly so a later field is
/// not misparsed) and stops rather than throws on a malformed varint length.
Iterable<_ProtoField> _protoFields(Uint8List data) sync* {
  var i = 0;
  int readVarint() {
    var result = 0, shift = 0;
    while (i < data.length) {
      final b = data[i++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
    throw const FormatException('truncated varint');
  }

  try {
    while (i < data.length) {
      final tag = readVarint();
      final number = tag >> 3;
      final wireType = tag & 0x7;
      switch (wireType) {
        case 0:
          yield _ProtoField(number, wireType, varint: readVarint());
        case 1:
          if (i + 8 > data.length) return;
          i += 8;
        case 2:
          final len = readVarint();
          if (i + len > data.length) return;
          yield _ProtoField(number, wireType,
              bytes: Uint8List.sublistView(data, i, i + len));
          i += len;
        case 5:
          if (i + 4 > data.length) return;
          i += 4;
        default:
          return; // an unsupported wire type; stop rather than misread
      }
    }
  } on FormatException {
    return;
  }
}

/// The `Smart{ device_status_service{ remote_device_battery_status_request{} } }`
/// request: two nested empty length-delimited messages. An empty embedded
/// message still marks the field present on the wire (tag + zero length),
/// which is how proto2 "optional" presence is expressed for a field with no
/// members of its own.
Uint8List garminBatteryRequestProto() =>
    _protoLenDelim(8, _protoLenDelim(2, const <int>[]));

/// One `RemoteDeviceBatteryStatusResponse`. `status` is null when the watch
/// omitted the field — not the same as a healthy reading.
class GarminBatteryStatus {
  final int? status;
  final int level;
  const GarminBatteryStatus({this.status, required this.level});
}

/// Decode a `Smart` envelope down to its battery status response, or null
/// when this message does not carry one (a different sub-service answered,
/// or the level was never set).
GarminBatteryStatus? garminParseBatteryResponseProto(Uint8List smartBytes) {
  for (final top in _protoFields(smartBytes)) {
    if (top.number != 8 || top.bytes == null) continue;
    for (final svc in _protoFields(top.bytes!)) {
      if (svc.number != 3 || svc.bytes == null) continue;
      int? status;
      int? level;
      for (final f in _protoFields(svc.bytes!)) {
        if (f.number == 1 && f.varint != null) status = f.varint;
        if (f.number == 2 && f.varint != null) level = f.varint;
      }
      if (level == null) return null;
      return GarminBatteryStatus(status: status, level: level);
    }
  }
  return null;
}
