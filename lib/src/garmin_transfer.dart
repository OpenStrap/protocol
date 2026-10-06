// Garmin GFDI file transfer and the two handshake replies a watch waits for
// before it will sync: everything needed to list the watch's files and
// download the FIT files that hold its health data.
//
// DOWNLOAD (phone -> watch, 5002): `u16 index | u32 offset | u8 type (1 new,
// 0 continue) | u16 crcSeed | u32 size (0 = whole file) | u8 flags 0`.
// The watch answers with a RESPONSE for 5002:
// `u16 ref | u8 status | u8 downloadStatus | u32 fileSize`, downloadStatus
// one of 0 ok, 1 no such index, 2 not readable, 3 not ready (ask again
// shortly), 4 invalid request, 5 CRC mismatch, 6 exceeds size. Then it
// streams FILE_TRANSFER_DATA (5004): `u8 flags | u16 crc | u32 offset | data`,
// where `crc` is the running CRC over the file so far (seeded with the
// previous chunk's). Every chunk is answered with a RESPONSE for 5004:
// `u16 ref | u8 status 0 | u8 transferStatus | u32 nextOffset`,
// transferStatus one of 0 ok (also a repeat of the last accepted chunk),
// 2 abort, 3 CRC mismatch, 4 offset mismatch.
//
// DIRECTORY: file index 0 lists the watch's files after a 16-byte header
// record, 16 bytes each: `u16 index | u8 dataType | u8 subType |
// u16 fileNumber | u8 specific | u8 flags | u32 size | u32 timestamp (Garmin
// epoch)`. FIT files are dataType 128; subType names the content
// (32 monitoring, 49 sleep, 68 HRV status, ...).
//
// NOT HERE: the archive flag (SET_FILE_FLAG). It removes a file from the
// watch's "new" list; this app never sends it and tracks what it has read
// per file (index, timestamp, size) instead, so the watch is left exactly as
// it was.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'garmin.dart';

const int kGarminMsgDownloadRequest = 5002;
const int kGarminMsgFileTransferData = 5004;
const int kGarminMsgConfiguration = 5050;

const int kGarminFileTypeFit = 128;
const int kGarminFitMonitor = 32;
const int kGarminFitSleep = 49;
const int kGarminFitHrvStatus = 68;

/// The FIT sub-types worth downloading for health data.
const Set<int> kGarminHealthFitSubTypes = {
  kGarminFitMonitor,
  kGarminFitSleep,
  kGarminFitHrvStatus,
};

Uint8List garminBuildDownloadRequest(int index,
    {int offset = 0, bool newTransfer = true, int crcSeed = 0}) {
  final b = ByteData(14)
    ..setUint16(0, index, Endian.little)
    ..setUint32(2, offset, Endian.little)
    ..setUint8(6, newTransfer ? 1 : 0)
    ..setUint16(7, crcSeed, Endian.little)
    ..setUint32(9, 0, Endian.little)
    ..setUint8(13, 0);
  return garminBuildGfdiFrame(
      kGarminMsgDownloadRequest, b.buffer.asUint8List());
}

/// Download statuses with a meaning beyond "refused".
const int kGarminDownloadNoSuchIndex = 1;
const int kGarminDownloadNotReadable = 2;
const int kGarminDownloadNotReady = 3;

/// The watch's answer to a download request: whether it will send, its
/// download status, and how many bytes. Null when [f] is not that answer.
({bool ok, int downloadStatus, int size})? garminParseDownloadStatus(
    GarminGfdiFrame f) {
  if (garminMessageType(f.type) != kGarminMsgResponse ||
      f.payload.length < 8) {
    return null;
  }
  final v = ByteData.sublistView(f.payload);
  if (garminMessageType(v.getUint16(0, Endian.little)) !=
      kGarminMsgDownloadRequest) {
    return null;
  }
  return (
    ok: v.getUint8(2) == 0 && v.getUint8(3) == 0,
    downloadStatus: v.getUint8(3),
    size: v.getUint32(4, Endian.little),
  );
}

/// One chunk of a file being downloaded.
class GarminFileChunk {
  final int crc;
  final int offset;
  final Uint8List data;
  const GarminFileChunk(this.crc, this.offset, this.data);
}

GarminFileChunk? garminParseFileChunk(GarminGfdiFrame f) {
  if (garminMessageType(f.type) != kGarminMsgFileTransferData ||
      f.payload.length < 7) {
    return null;
  }
  final v = ByteData.sublistView(f.payload);
  return GarminFileChunk(v.getUint16(1, Endian.little),
      v.getUint32(3, Endian.little), f.payload.sublist(7));
}

/// Chunk transfer statuses.
const int kGarminTransferOk = 0;
const int kGarminTransferAbort = 2;
const int kGarminTransferCrcMismatch = 3;
const int kGarminTransferOffsetMismatch = 4;

/// Acknowledge a chunk with [status] and the next offset expected, as a
/// RESPONSE of [responseType] (see [garminResponseType]).
Uint8List garminBuildChunkAck(int nextOffset,
    {int status = kGarminTransferOk,
    int responseType = kGarminMsgResponse}) {
  final b = ByteData(8)
    ..setUint16(0, kGarminMsgFileTransferData, Endian.little)
    ..setUint8(2, 0)
    ..setUint8(3, status)
    ..setUint32(4, nextOffset, Endian.little);
  return garminBuildGfdiFrame(responseType, b.buffer.asUint8List());
}

/// One directory entry.
class GarminFileEntry {
  final int index;
  final int dataType;
  final int subType;
  final int fileNumber;
  final int size;

  /// Unix seconds.
  final int timestamp;
  const GarminFileEntry(this.index, this.dataType, this.subType,
      this.fileNumber, this.size, this.timestamp);

  bool get isHealthFit =>
      dataType == kGarminFileTypeFit &&
      kGarminHealthFitSubTypes.contains(subType);
}

/// The entries of a directory file, after its 16-byte header record.
List<GarminFileEntry> garminParseDirectory(List<int> bytes) {
  final b = Uint8List.fromList(bytes);
  final v = ByteData.sublistView(b);
  return [
    for (var i = 16; i + 16 <= b.length; i += 16)
      GarminFileEntry(
        v.getUint16(i, Endian.little),
        b[i + 2],
        b[i + 3],
        v.getUint16(i + 4, Endian.little),
        v.getUint32(i + 8, Endian.little),
        v.getUint32(i + 12, Endian.little) + kGarminEpochOffset,
      ),
  ];
}

/// The protocol version the phone states: 113, the version before
/// transaction ids. This code echoes a request's transaction id but never
/// numbers its own requests, so it does not claim 150.
const int kGarminHostProtocolVersion = 113;

/// The phone's own device information, the one RESPONSE the watch's 5024
/// gets: protocol version, product / unit / software ids, max packet, then
/// host name, manufacturer and model as length-prefixed strings (each cut
/// to 255 bytes), then a 0x01.
Uint8List garminBuildDeviceInfoReply({
  String name = 'OpenStrap',
  String manufacturer = '',
  String model = '',
  int appVersion = 1,
  int responseType = kGarminMsgResponse,
}) {
  List<int> str(String s) {
    final u = utf8.encode(s);
    final cut = u.length > 255 ? u.sublist(0, 255) : u;
    return [cut.length, ...cut];
  }

  final head = ByteData(15)
    ..setUint16(0, kGarminMsgDeviceInformation, Endian.little)
    ..setUint8(2, 0)
    ..setUint16(3, kGarminHostProtocolVersion, Endian.little)
    ..setUint16(5, 0xffff, Endian.little) // product
    ..setUint32(7, 0xffffffff, Endian.little) // unit id
    ..setUint16(11, appVersion & 0xffff, Endian.little) // software version
    ..setUint16(13, 0xffff, Endian.little); // max packet size
  return garminBuildGfdiFrame(responseType, [
    ...head.buffer.asUint8List(),
    ...str(name),
    ...str(manufacturer),
    ...str(model),
    1,
  ]);
}

/// Capability bits (CONFIGURATION, 5050).
const int kGarminCapDeviceInitiatesSync = 4;
const int kGarminCapCurrentTimeRequest = 71;
const int kGarminCapSync2 = 90;

/// The capabilities this phone implements: answering the watch's time
/// request. Nothing else is claimed.
const Set<int> kGarminHostCapabilities = {kGarminCapCurrentTimeRequest};

/// The capability bits a CONFIGURATION (5050) frame carries:
/// `u8 length | bitset`, bit n in byte n ~/ 8, bit n % 8. Null when [f] is
/// not one.
Set<int>? garminParseConfiguration(GarminGfdiFrame f) {
  if (garminMessageType(f.type) != kGarminMsgConfiguration ||
      f.payload.isEmpty) {
    return null;
  }
  final n = f.payload[0].clamp(0, f.payload.length - 1);
  return {
    for (var i = 0; i < n * 8; i++)
      if (f.payload[1 + i ~/ 8] & (1 << (i % 8)) != 0) i,
  };
}

/// The phone's own CONFIGURATION (5050): `u8 length | bitset` with only
/// [bits] set, length the fewest bytes that hold the highest one.
Uint8List garminBuildConfigurationReply(
    [Set<int> bits = kGarminHostCapabilities]) {
  final top = bits.fold(0, (a, b) => b > a ? b : a);
  final set = List.filled(top ~/ 8 + 1, 0);
  for (final b in bits) {
    set[b ~/ 8] |= 1 << (b % 8);
  }
  return garminBuildGfdiFrame(kGarminMsgConfiguration, [set.length, ...set]);
}
