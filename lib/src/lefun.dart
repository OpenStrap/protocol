// A shared OEM wire format used across a family of white-label BLE fitness
// rings and bands sold under many storefront names on one common reference
// design. One write/notify characteristic pair, one small envelope, plain
// unencrypted GATT.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The envelope and its
// checksum are the only things this file decodes with confidence — battery
// level is the one report this file turns into a value, because it is a
// single bounded byte with an unambiguous meaning. Steps, sleep, heart rate
// and PPG all ride the same envelope under their own report codes, and none
// of them has a decoder here: a layout is not hardware-verified just because
// it is documented, and a wrong number is worse than no number.
//
// PLAIN, UNENCRYPTED GATT. There is no nonce, no key and no challenge/response
// anywhere in this envelope — a session is a bare write/notify pair from the
// moment the link connects.

/// Host to device.
const int kLefunRequestMarker = 0xAB;

/// Device to host.
const int kLefunResponseMarker = 0x5A;

/// Marker + length + report code + trailing checksum — the fixed part of
/// every frame regardless of direction.
const int kLefunHeaderLength = 4;

/// One GATT write/notify value never carries more than this many bytes.
const int kLefunMaxFrameLength = 20;

/// Report code: battery level. Same code both ways — a bare request with no
/// arguments, a one-byte percentage in reply.
const int kLefunReportBattery = 0x03;

/// Report code: firmware/type info. Request only; this file does not decode
/// the reply.
const int kLefunReportFirmwareInfo = 0x00;

/// The reflected CRC-8 this family's checksum byte turns out to be — bit 0 of
/// the running value against bit 0 of each input byte, shifting the byte out
/// LSB-first and feeding 0x18 back in on a mismatch. Computed bit-by-bit
/// rather than table-driven: the table costs 256 entries to save a function
/// this small ever needs to call more than once per frame.
int _lefunChecksum(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    var b = byte & 0xff;
    for (var bit = 0; bit < 8; bit++) {
      if (((b ^ crc) & 1) == 0) {
        crc >>= 1;
      } else {
        crc = ((crc ^ 0x18) >> 1) | 0x80;
      }
      b >>= 1;
    }
  }
  return crc & 0xff;
}

/// One decoded envelope: a report code and its argument bytes, checksum
/// already verified.
class LefunFrame {
  final int report;
  final List<int> params;
  const LefunFrame(this.report, this.params);
}

/// Throws unless [b] is a single wire byte. Every field this envelope carries
/// — the report code and every argument — is one GATT-frame byte, and a
/// caller passing something outside 0-255 would otherwise silently produce a
/// frame with a value no receiving device's byte reader can represent.
void _checkByte(int b, String name) {
  if (b < 0 || b > 0xff) {
    throw ArgumentError.value(b, name, 'must be a single byte (0-255)');
  }
}

/// Build one host-to-device frame. Throws if [params] would push the frame
/// past [kLefunMaxFrameLength] — there is no multi-segment chunking here, so a
/// command that cannot fit one write has no builder in this file — or if
/// [report] or any of [params] falls outside 0-255.
List<int> buildLefunFrame(int report, {List<int> params = const <int>[]}) {
  final length = kLefunHeaderLength + params.length;
  if (length > kLefunMaxFrameLength) {
    throw ArgumentError('Lefun frame does not fit one GATT write');
  }
  _checkByte(report, 'report');
  for (final p in params) {
    _checkByte(p, 'params');
  }
  final body = <int>[kLefunRequestMarker, length, report, ...params];
  return <int>[...body, _lefunChecksum(body)];
}

/// Parse one device-to-host frame. Null for anything too short, missing the
/// response marker, declaring a length outside `kLefunHeaderLength ..
/// kLefunMaxFrameLength`, or whose checksum does not match — any of those
/// means a partial or corrupted delivery, never a value to patch up and keep.
///
/// A DECLARED LENGTH SHORTER THAN THE BUFFER IS ACCEPTED, deliberately: this
/// codec has not been checked against a real capture, and a device in this
/// family appending bytes past its own declared length — the way the Oura
/// ring is known to (see `oura.dart`) — would otherwise have every one of its
/// notifications refused outright instead of parsed with the extra bytes
/// available to whoever archives the raw delivery.
LefunFrame? parseLefunFrame(List<int> value) {
  if (value.length < kLefunHeaderLength) return null;
  if (value[0] != kLefunResponseMarker) return null;
  final length = value[1];
  if (length < kLefunHeaderLength ||
      length > kLefunMaxFrameLength ||
      length > value.length) {
    return null;
  }
  final body = value.sublist(0, length - 1);
  if (_lefunChecksum(body) != value[length - 1]) return null;
  return LefunFrame(value[2], value.sublist(3, length - 1));
}

/// Decode a battery report's single-byte argument. Null when the argument
/// count is wrong or the value falls outside 0-100 — either means a misread,
/// not a percentage to clamp and keep.
int? decodeLefunBattery(List<int> params) {
  if (params.length != 1) return null;
  final level = params[0];
  if (level < 0 || level > 100) return null;
  return level;
}
