import 'dart:typed_data';

import 'package:openstrap_protocol/src/garmin.dart';
import 'package:openstrap_protocol/src/garmin_transfer.dart';
import 'package:test/test.dart';

GarminGfdiFrame frame(Uint8List built) => garminParseGfdiFrame(built)!;

void main() {
  test('compact message ids expand to 5000 + low byte', () {
    expect(garminMessageType(0x8000 | 4), 5004);
    expect(garminMessageType(5004), 5004);
  });

  test('download request layout', () {
    final f = frame(garminBuildDownloadRequest(0x0102));
    expect(f.type, kGarminMsgDownloadRequest);
    expect(f.payload, [0x02, 0x01, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]);
  });

  test('download status and chunk parsing', () {
    final status = garminBuildGfdiFrame(kGarminMsgResponse, [
      0x8a, 0x13, 0, 0, 0x40, 0, 0, 0, // ref 5002, ok, ok, 64 bytes
    ]);
    expect(garminParseDownloadStatus(frame(status)),
        (ok: true, downloadStatus: 0, size: 64));
    final notReady = garminBuildGfdiFrame(kGarminMsgResponse, [
      0x8a, 0x13, 0, 3, 0, 0, 0, 0, // ref 5002, ok, not ready
    ]);
    expect(garminParseDownloadStatus(frame(notReady)),
        (ok: false, downloadStatus: kGarminDownloadNotReady, size: 0));
    final chunk = garminBuildGfdiFrame(kGarminMsgFileTransferData,
        [0, 0x34, 0x12, 16, 0, 0, 0, 9, 8, 7]);
    final c = garminParseFileChunk(frame(chunk))!;
    expect((c.crc, c.offset), (0x1234, 16));
    expect(c.data, [9, 8, 7]);
  });

  test('chunk ack carries the next offset', () {
    final f = frame(garminBuildChunkAck(48));
    expect(f.payload, [0x8c, 0x13, 0, 0, 48, 0, 0, 0]);
    expect(
        frame(garminBuildChunkAck(48,
                status: kGarminTransferOffsetMismatch))
            .payload[3],
        4);
  });

  test('a compact-form request is answered with its transaction id', () {
    const compact = 0x8000 | (5 << 8) | 4; // FILE_TRANSFER_DATA, txn 5
    expect(garminTransactionId(compact), 5);
    expect(garminTransactionId(5004), isNull);
    final ack = garminBuildChunkAck(8, responseType: garminResponseType(compact));
    expect(ack.sublist(2, 4), [0x00, 0x85]);
    expect(garminMessageType(frame(ack).type), kGarminMsgResponse);
    expect(frame(garminBuildChunkAck(8)).type, kGarminMsgResponse);
  });

  test('directory entries: health FIT files are recognised', () {
    final ts = 1000;
    final e = garminParseDirectory([
      // The header record, never an entry even when it looks like one.
      0x01, 0, 128, 32, 0x10, 0, 0, 0, 0x00, 0x10, 0, 0, 0, 0, 0, 0,
      0x05, 0, 128, 32, 0x10, 0, 0, 0, 0x00, 0x10, 0, 0, ts & 0xff, ts >> 8, 0, 0,
      0x06, 0, 128, 4, 0x11, 0, 0, 0, 0x00, 0x02, 0, 0, 0, 0, 0, 0,
    ]);
    expect(e.map((x) => (x.index, x.subType, x.size, x.isHealthFit)),
        [(5, 32, 4096, true), (6, 4, 512, false)]);
    expect(e.first.timestamp, ts + kGarminEpochOffset);
  });

  test('device info reply: version 113, host strings, trailing 0x01', () {
    final d = frame(garminBuildDeviceInfoReply(
        name: 'OS', manufacturer: 'acme', model: 'p1', appVersion: 7));
    expect(d.type, kGarminMsgResponse);
    expect(d.payload.sublist(0, 3), [0xa0, 0x13, 0]); // ref 5024, ok
    final v = ByteData.sublistView(d.payload);
    expect(v.getUint16(3, Endian.little), 113);
    expect(v.getUint16(11, Endian.little), 7);
    expect(d.payload.sublist(15), [
      2, ...'OS'.codeUnits, 4, ...'acme'.codeUnits, 2, ...'p1'.codeUnits, 1,
    ]);
    final long = frame(garminBuildDeviceInfoReply(name: 'x' * 300));
    expect(long.payload[15], 255);
  });

  test('configuration: only the time-request capability is claimed', () {
    final c = frame(garminBuildConfigurationReply());
    expect(c.type, kGarminMsgConfiguration);
    expect(c.payload, [9, 0, 0, 0, 0, 0, 0, 0, 0, 0x80]); // bit 71
    expect(garminParseConfiguration(c), {kGarminCapCurrentTimeRequest});
    final watch = frame(garminBuildGfdiFrame(
        kGarminMsgConfiguration, [2, 0x10, 0x01])); // bits 4 and 8
    expect(garminParseConfiguration(watch), {4, 8});
  });

  test('a running CRC over two chunks equals the CRC over the whole', () {
    final a = [1, 2, 3, 4], b = [5, 6, 7];
    expect(garminCrc16(b, garminCrc16(a)), garminCrc16([...a, ...b]));
  });
}
