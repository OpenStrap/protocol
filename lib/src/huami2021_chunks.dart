// Huami2021 chunked transport (chars 0016 write / 0017 notify): logical
// endpoint messages split into BLE writes, and reassembled (and decrypted)
// on the way back.
//
// Chunk header — marker 0x03 · flags · 0x00 · handle · count; the FIRST chunk
// then carries the ORIGINAL (plaintext) length u32 LE and the endpoint u16 LE.
// Flags: 0x01 first, 0x02 last, 0x04 needs-ACK (set with last), 0x08 encrypted.
// Handle is one per message, (prev + 1) & 0xFF, starting at 1.
//
// Encrypted message: key[i] = sessionKey[i] ^ handle, AES-128-ECB, plaintext =
// data | seq u32 LE | crc32(data | seq) u32 LE, zero-padded to 16.
//
// The cipher is passed in so this package stays dependency-free (the edge
// adapter owns AES, as it does for the other framed bands).

import 'dart:typed_data';

import 'crc.dart' show crc32;

/// AES-128-ECB, no padding. [data] is a multiple of 16 bytes.
typedef AesEcb = Uint8List Function(Uint8List key, Uint8List data);

const int _marker = 0x03;
const int _flagFirst = 0x01;
const int _flagLast = 0x02;
const int _flagNeedsAck = 0x04;
const int _flagEncrypted = 0x08;
const int _firstHeader = 11;
const int _nextHeader = 5;

/// The ATT MTU the strap grants; chunk sizes depend on it.
const int kHuami2021DefaultMtu = 247;

/// Chunked WRITE (app -> strap).
const String kHuami2021ChunkWriteChar = '00000016-0000-3512-2118-0009af100700';

/// Chunked NOTIFY (strap -> app); ACKs are also written here.
const String kHuami2021ChunkNotifyChar = '00000017-0000-3512-2118-0009af100700';

/// `data | seq(4) | crc32(4)` rounded up to a 16-byte multiple.
int huami2021PaddedLength(int originalLength) {
  final raw = originalLength + 8;
  return raw % 16 == 0 ? raw : raw + 16 - raw % 16;
}

Uint8List _messageKey(Uint8List sessionKey, int handle) =>
    Uint8List.fromList([for (final b in sessionKey) b ^ handle]);

/// The ACK the strap expects on 0017 after a frame flagged needs-ACK.
Uint8List huami2021Ack(int handle, int count) =>
    Uint8List.fromList([0x04, 0x00, handle & 0xff, 0x01, count & 0xff]);

/// Splits outgoing messages into chunks. One encoder per connection.
class Huami2021Encoder {
  Huami2021Encoder({this.mtu = kHuami2021DefaultMtu, AesEcb? encrypt})
      : _aesEncrypt = encrypt;

  final int mtu;
  final AesEcb? _aesEncrypt;
  int _handle = 0;
  Uint8List? _key;
  int _seq = 0;

  /// Arms encryption for later `encrypt: true` messages.
  void setEncryption(Uint8List sessionKey, int sequence) {
    if (sessionKey.length != 16) {
      throw ArgumentError('session key must be 16 bytes');
    }
    _key = Uint8List.fromList(sessionKey);
    _seq = sequence & 0xFFFFFFFF;
  }

  List<Uint8List> encode(int endpoint, List<int> data, {bool encrypt = false}) {
    _handle = (_handle + 1) & 0xFF;
    final body = encrypt ? _encrypt(Uint8List.fromList(data)) : data;
    final chunks = <Uint8List>[];
    var offset = 0;
    var count = 0;
    do {
      final first = count == 0;
      final header = first ? _firstHeader : _nextHeader;
      final budget = (mtu - 3 - header).clamp(1, 1 << 30);
      final remaining = body.length - offset;
      final take = remaining < budget ? remaining : budget;
      final last = remaining <= budget;
      var flags = first ? _flagFirst : 0;
      if (encrypt) flags |= _flagEncrypted;
      if (last) flags |= _flagLast | _flagNeedsAck;
      final chunk = Uint8List(header + take);
      final bd = ByteData.sublistView(chunk);
      chunk[0] = _marker;
      chunk[1] = flags;
      chunk[3] = _handle;
      chunk[4] = count;
      if (first) {
        bd.setUint32(5, data.length, Endian.little); // ORIGINAL length
        bd.setUint16(9, endpoint, Endian.little);
      }
      chunk.setRange(header, header + take, body, offset);
      chunks.add(chunk);
      offset += take;
      count++;
    } while (offset < body.length);
    return chunks;
  }

  Uint8List _encrypt(Uint8List data) {
    final key = _key;
    final aes = _aesEncrypt;
    if (key == null || aes == null) {
      throw StateError('encrypt requested without a session key or cipher');
    }
    final plain = Uint8List(huami2021PaddedLength(data.length));
    plain.setRange(0, data.length, data);
    final bd = ByteData.sublistView(plain);
    bd.setUint32(data.length, _seq, Endian.little);
    _seq = (_seq + 1) & 0xFFFFFFFF;
    bd.setUint32(data.length + 4, crc32(plain.sublist(0, data.length + 4)),
        Endian.little);
    return aes(_messageKey(key, _handle), plain);
  }
}

/// One reassembled logical message.
class Huami2021Frame {
  const Huami2021Frame(this.endpoint, this.payload, this.encrypted,
      this.needsAck, this.handle, this.count);
  final int endpoint;
  final Uint8List payload;
  final bool encrypted;
  final bool needsAck;
  final int handle;
  final int count;
}

/// Reassembles chunks arriving on 0017. One decoder per connection.
class Huami2021Decoder {
  Huami2021Decoder({AesEcb? decrypt}) : _aesDecrypt = decrypt;

  final AesEcb? _aesDecrypt;
  int? _handle;
  int _endpoint = 0;
  int _length = 0;
  bool _encrypted = false;
  int _nextCount = 0;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Feeds one notification. Returns the frame on its last chunk, else null.
  /// Malformed, out-of-sequence, undecryptable or CRC-mismatched input
  /// returns null and resets: the caller sees no frame, never garbage —
  /// specifically:
  ///  * a chunk with no preceding first-chunk for this handle is an orphan
  ///    and is rejected, not treated as an empty message on endpoint 0;
  ///  * `count` must run 0, 1, 2, ... with no gap — a chunk that skips
  ///    ahead (a dropped middle chunk) or repeats is rejected rather than
  ///    silently reassembled into a truncated or duplicated payload;
  ///  * an encrypted message's trailing `seq | crc32(data|seq)` is checked
  ///    after decryption, so a wrong session key yields null, never the
  ///    garbage AES-ECB happens to produce under the wrong key.
  Huami2021Frame? feed(List<int> data, {Uint8List? sessionKey}) {
    if (data.length < 5 || data[0] != _marker) return null;
    final flags = data[1];
    final chunkHandle = data[3];
    final count = data[4];
    final isFirst = flags & _flagFirst != 0;
    if (_handle == null && !isFirst) return null; // orphan: no first chunk seen
    if (_handle != null && _handle != chunkHandle) return null;
    var offset = 5;
    if (isFirst) {
      if (data.length < offset + 6) return null;
      final bd = ByteData.sublistView(Uint8List.fromList(data));
      _length = bd.getUint32(offset, Endian.little);
      _endpoint = bd.getUint16(offset + 4, Endian.little);
      _encrypted = flags & _flagEncrypted != 0;
      _buffer.clear();
      _handle = chunkHandle;
      _nextCount = 0;
      offset += 6;
    }
    if (count != _nextCount) {
      _reset();
      return null;
    }
    _nextCount++;
    _buffer.add(data.sublist(offset));
    if (flags & _flagLast == 0) return null;
    final payload = _assemble(sessionKey, chunkHandle);
    final frame = payload == null
        ? null
        : Huami2021Frame(_endpoint, payload, _encrypted,
            flags & _flagNeedsAck != 0, chunkHandle, count);
    _reset();
    return frame;
  }

  Uint8List? _assemble(Uint8List? sessionKey, int chunkHandle) {
    var all = _buffer.toBytes();
    if (_encrypted) {
      final aes = _aesDecrypt;
      if (sessionKey == null || aes == null) return null;
      final cipherLength = huami2021PaddedLength(_length);
      if (all.length < cipherLength) return null;
      all = aes(_messageKey(sessionKey, chunkHandle),
          Uint8List.sublistView(all, 0, cipherLength));
      // Verify the trailing seq|crc32 the encoder writes — a wrong session
      // key decrypts to garbage with nothing else to catch it.
      if (all.length < _length + 8) return null;
      final bd = ByteData.sublistView(all);
      final crc = bd.getUint32(_length + 4, Endian.little);
      final want = crc32(all.sublist(0, _length + 4));
      if (crc != want) return null;
    }
    final n = _length < all.length ? _length : all.length;
    return Uint8List.sublistView(all, 0, n);
  }

  void _reset() {
    _handle = null;
    _endpoint = 0;
    _length = 0;
    _encrypted = false;
    _nextCount = 0;
    _buffer.clear();
  }
}
