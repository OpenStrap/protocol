// Framing — WHOOP 4.0 protocol (Gen4 / "Harvard" envelope).
//
// Frame: [0xAA SOF][u16 LE size][crc8(size)][inner, padded /4][u32 LE CRC32]
//   size = len(inner_padded) + 4  (counts the trailing CRC32)
//
// The reassembler MUST be length-based, NOT "reset on 0xAA" — sensor payloads
// contain 0xAA and BLE notification boundaries land on them. See
//
// PURE Dart — no Flutter, no I/O.

import 'dart:typed_data';
import 'crc.dart';
import 'constants.dart';
import 'band.dart';

/// A fully-parsed, validated frame envelope.
class Frame {
  final Uint8List inner; // unpadded? no — padded inner (type, seq, opcode, body…)

  /// Header-integrity check result. Named `crc8Ok` for backward compatibility
  /// (gen4 header uses crc8); on gen5 it carries the crc16-modbus result. Use
  /// [headerCrcOk] for band-neutral code.
  final bool crc8Ok;
  final bool crc32Ok;

  Frame(this.inner, this.crc8Ok, this.crc32Ok);

  /// Band-neutral alias for the header-integrity result.
  bool get headerCrcOk => crc8Ok;

  bool get valid => crc8Ok && crc32Ok;
  int get packetType => inner.isNotEmpty ? inner[0] : -1;
  int get seq => inner.length > 1 ? inner[1] : -1;
  int get opcode => inner.length > 2 ? inner[2] : -1;
  Uint8List get body =>
      inner.length > 3 ? Uint8List.sublistView(inner, 3) : Uint8List(0);
}

/// Zero-pad to a 4-byte boundary (CRC32 is computed over the padded form).
Uint8List pad4(List<int> data) {
  final padLen = (-data.length) % 4;
  final out = Uint8List(data.length + (padLen < 0 ? padLen + 4 : padLen));
  out.setRange(0, data.length, data);
  return out;
}

/// Wrap inner content in a frame envelope. [profile] selects the generation's
/// header shape; defaults to gen4 (WHOOP 4) so every existing caller is
/// byte-for-byte unchanged. The padded inner + trailing CRC32 are identical
/// across generations — only the header differs.
Uint8List buildFrame(List<int> inner, {BandProfile profile = BandProfile.gen4}) {
  final innerP = pad4(inner);
  final declared = innerP.length + 4; // +4 = trailing CRC32
  final header = profile.buildHeader(declared);
  final c32 = crc32(innerP);

  final out = BytesBuilder();
  out.add(header);
  out.add(innerP);
  final tail = Uint8List(4)..buffer.asByteData().setUint32(0, c32, Endian.little);
  out.add(tail);
  return out.toBytes();
}

/// Parse a single complete frame. Returns null if too short / bad SOF.
/// [profile] selects the generation's header shape (default gen4).
Frame? parseFrame(Uint8List raw, {BandProfile profile = BandProfile.gen4}) {
  final headerLen = profile.headerLen;
  if (raw.length < headerLen + 4 || raw[0] != sof) return null;
  final declared = profile.declaredLen(raw);
  // declared has to be at least 4 (the trailing crc32) or the inner slice
  // math below goes negative and sublistView throws instead of us just
  // saying "not a valid frame" like the length checks above already do.
  if (declared < 4) return null;
  final headerCrcOk = profile.headerCrcValid(raw);
  final innerStart = headerLen;
  final total = headerLen + declared;
  if (raw.length < total) return null;
  // inner = raw[headerLen : headerLen + declared - 4]
  final inner = Uint8List.sublistView(raw, innerStart, innerStart + declared - 4);
  final storedBd =
      raw.buffer.asByteData(raw.offsetInBytes + innerStart + declared - 4, 4);
  final stored = storedBd.getUint32(0, Endian.little);
  return Frame(Uint8List.fromList(inner), headerCrcOk, stored == crc32(inner));
}

/// Length-based reassembler. feed() returns every complete Frame it can carve
/// out of the running buffer. [profile] selects the generation's header shape;
/// defaults to gen4 so the WHOOP 4 path is unchanged. Construct ONE per
/// BLE session (a session speaks one generation).
class FrameReassembler {
  final List<int> _buf = [];
  final BandProfile profile;

  FrameReassembler({this.profile = BandProfile.gen4});

  List<Frame> feed(List<int> chunk) {
    final out = <Frame>[];
    _buf.addAll(chunk);

    bool resync() {
      // Find next SOF after index 0.
      int nxt = -1;
      for (int i = 1; i < _buf.length; i++) {
        if (_buf[i] == sof) {
          nxt = i;
          break;
        }
      }
      if (nxt < 0) {
        _buf.clear();
        return false;
      }
      _buf.removeRange(0, nxt);
      return true;
    }

    final headerLen = profile.headerLen;
    while (_buf.length >= headerLen + 4) {
      if (_buf[0] != sof) {
        if (!resync()) break;
        continue;
      }
      final declared = profile.declaredLen(_buf); // u16 LE
      final total = headerLen + declared;
      if (declared < 4 || total > 4096) {
        // implausible length → spurious SOF
        if (!resync()) break;
        continue;
      }
      if (_buf.length < total) break; // wait for the rest of this frame
      final frame =
          parseFrame(Uint8List.fromList(_buf.sublist(0, total)), profile: profile);
      if (frame != null) out.add(frame);
      _buf.removeRange(0, total);
      // skip inter-record null padding
      int i = 0;
      while (i < _buf.length && _buf[i] == 0x00) {
        i++;
      }
      if (i > 0) _buf.removeRange(0, i);
    }
    if (_buf.length > 8192) _buf.clear(); // safety: never grow unbounded
    return out;
  }

  void reset() => _buf.clear();
}
