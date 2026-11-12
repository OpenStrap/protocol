// Device image update commands (gen5 only). Pure payload builders: nothing
// here sends anything, and none of these opcodes may leave the host without
// the caller's explicit allowDangerous opt-in (0x8E, 0x8F and 0x90 are
// destructive; 0x53 only asks the strap to check what is staged).
//
//   0x8E start load     [0x01]
//   0x8F load data      [0x01][offset u32 LE][len u8][data]
//   0x53 verify image   [0x01]
//   0x90 process image  [0x01]   — commit; cannot be undone from the host.
//
// A status of 1 on 0x90 only means the staged bytes were accepted and
// checksummed. It is not proof the image is now running.
import 'dart:typed_data';

class FwUpdate {
  static const int startLoad = 0x8E;
  static const int loadData = 0x8F;
  static const int verifyImage = 0x53;
  static const int processImage = 0x90;

  /// Length field of [loadData] is one byte.
  static const int maxChunk = 255;

  /// Bytes per [loadData]. Small enough that the framed write fits a typical
  /// negotiated ATT payload (8 header + padded 9+128 inner + 4 crc = 152).
  static const int chunk = 128;

  static const List<int> rev1 = [0x01];

  static Uint8List loadDataPayload(int offset, List<int> data) {
    if (data.isEmpty || data.length > maxChunk) {
      throw ArgumentError('chunk must be 1..$maxChunk bytes, got ${data.length}');
    }
    if (offset < 0 || offset > 0xFFFFFFFF) {
      throw ArgumentError('offset out of u32 range: $offset');
    }
    final b = BytesBuilder()
      ..addByte(0x01)
      ..add((ByteData(4)..setUint32(0, offset, Endian.little))
          .buffer
          .asUint8List())
      ..addByte(data.length)
      ..add(data);
    return b.toBytes();
  }

  static int chunkCount(int imageLen) {
    if (imageLen <= 0) throw ArgumentError('image length must be > 0, got $imageLen');
    return (imageLen + chunk - 1) ~/ chunk;
  }
}
