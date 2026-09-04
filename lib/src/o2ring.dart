// Wellue O2Ring pulse-oximeter ring: wire envelope only.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one, so this is
// verified the same way `oura.dart` is: independent published documentation,
// one byte-exact test vector, and the compiler. It ships EXPERIMENTAL until an
// owner cross-confirms it.
//
// THE ENVELOPE IS PROVEN, NOT GUESSED. `[0xAA][cmd][cmd^0xFF][block
// u16LE][len u16LE][data...][crc8]` and the trailing byte is [crc8] over
// everything before it — the SAME CRC-8 (poly 0x07, non-reflected) this
// package already ships for WHOOP's header, just applied over a wider span.
// The no-payload request this file builds for opcode 0x17 comes out
// byte-for-byte `AA 17 E8 00 00 00 00 1B`, which is an independently
// published, hardware-captured request for this exact ring family — the one
// external fact this module is checked against.
//
// WHAT IS DELIBERATELY NOT HERE. Every documented account of this ring's file
// commands (open/read/close a stored recording) disagrees with the envelope
// above on where the status and size fields land inside the reply — one
// reading only makes sense if "byte 1" means something other than the
// envelope's own byte 1. Guessing a byte order to drive a read-until-done
// loop is exactly the fabricated-decoder failure this project refuses, so
// there is no file-open/file-read/file-close builder here. Only the frame
// envelope and the one command whose reply is unambiguous prose (INFO's JSON)
// are exposed. A future session with a real ring should confirm the file
// commands against it before this module grows them.
//
// NO PHYSIOLOGICAL FIELD IS DECODED, ANYWHERE IN THIS FILE, ON PURPOSE. This
// ring's real-time reply layout (SpO2, pulse, perfusion index) is published
// and even hardware-tested elsewhere, and none of it is reproduced here: this
// project's own rule is that "documented" is not "hardware-verified", and the
// only thing this module hands back from a notification is the frame it
// arrived in, for the caller to archive verbatim.

import 'dart:convert';
import 'dart:typed_data';

import 'crc.dart' show crc8;

/// One frame off the notify characteristic, with its CRC already checked.
class O2RingFrame {
  /// The command byte this frame answers (or carries, for a request the
  /// caller built with [buildO2RingCommand]).
  final int cmd;

  /// The block field. Meaningful only for file commands, which this module
  /// does not build — carried through unconditionally since it costs nothing
  /// to keep.
  final int block;

  /// The payload after the 7-byte header and before the trailing CRC byte.
  final Uint8List data;

  const O2RingFrame(this.cmd, this.block, this.data);
}

/// Parse one notification into a [O2RingFrame]. Null when the buffer is too
/// short, the header markers do not match, the declared length runs past the
/// buffer, or the trailing CRC-8 does not check out.
///
/// The CRC covers every byte from the leading `0xAA` through the end of
/// `data` — i.e. everything except the CRC byte itself, which is the reading
/// the byte-exact `0x17` test vector confirms (see this file's own header).
O2RingFrame? parseO2RingFrame(List<int> value) {
  if (value.length < 8) return null;
  if (value[0] != 0xAA) return null;
  final cmd = value[1];
  if (value[2] != (cmd ^ 0xFF) & 0xFF) return null;
  final block = value[3] | (value[4] << 8);
  final len = value[5] | (value[6] << 8);
  final total = 7 + len + 1;
  if (value.length < total) return null;
  final body = value.sublist(0, 7 + len);
  if (crc8(body) != value[7 + len]) return null;
  return O2RingFrame(cmd, block, Uint8List.fromList(value.sublist(7, 7 + len)));
}

/// Build one outbound command frame: header, [data], then the CRC-8 trailer.
/// The complete frame, ready for `link.write`.
List<int> buildO2RingCommand(int cmd, {int block = 0, List<int> data = const []}) {
  final len = data.length;
  final body = <int>[
    0xAA,
    cmd & 0xFF,
    (cmd ^ 0xFF) & 0xFF,
    block & 0xFF,
    (block >> 8) & 0xFF,
    len & 0xFF,
    (len >> 8) & 0xFF,
    ...data,
  ];
  return <int>[...body, crc8(body)];
}

/// Device info / battery / stored-file list. No payload.
const int kO2RingCmdInfo = 0x14;

/// `buildO2RingCommand(kO2RingCmdInfo)`, named for the one call site.
List<int> o2ringCmdInfo() => buildO2RingCommand(kO2RingCmdInfo);

/// The ring's answer to [o2ringCmdInfo]: battery, model, serial and the
/// stored-file list, as a plain JSON object — not a bit-packed layout, so
/// unlike everything physiological this ring emits, there is no byte order to
/// get wrong here.
class O2RingInfo {
  final int? batteryPct;
  final String? model;
  final String? serial;

  /// Stored recording file names, oldest call order preserved.
  final List<String> files;

  const O2RingInfo({
    this.batteryPct,
    this.model,
    this.serial,
    this.files = const <String>[],
  });
}

/// Decode an INFO reply's payload. Null when it is not valid JSON or not a
/// JSON object — a caller should archive the frame either way and treat this
/// as best-effort metadata, never a gate on doing so.
O2RingInfo? parseO2RingInfo(List<int> data) {
  Object? obj;
  try {
    obj = jsonDecode(utf8.decode(data));
  } catch (_) {
    return null;
  }
  if (obj is! Map) return null;
  final bat = obj['CurBAT'];
  final pct = bat is String ? int.tryParse(bat.replaceAll('%', '')) : null;
  final rawFiles = obj['FileList'];
  final files = rawFiles is String && rawFiles.isNotEmpty
      ? [
          for (final f in rawFiles.split(','))
            if (f.trim().isNotEmpty) f.trim(),
        ]
      : const <String>[];
  return O2RingInfo(
    batteryPct: pct,
    model: obj['Model'] as String?,
    serial: obj['SN'] as String?,
    files: files,
  );
}
