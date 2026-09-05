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
// external fact the envelope math itself is checked against.
//
// THE ONE OPCODE THIS FILE ACTUALLY USES IS ALSO INDEPENDENTLY DOCUMENTED,
// SEPARATELY FROM THE ENVELOPE MATH. 0x14 is named INFO (empty request,
// JSON reply) in independently published protocol notes for this ring
// family, matching this file's own doc comment and its `O2RingInfo` field
// names below. That is a second, distinct external fact — the opcode value
// itself — layered on top of the byte-order proof above, not a substitute
// for it: nobody on this project has confirmed a real ring answers `AA 14
// EB 00 00 00 00 C6` (the deterministic frame the proven envelope produces
// for that opcode with no payload).
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
///
/// 0x14 is independently documented elsewhere as this ring family's INFO
/// opcode — see this file's header for what that external fact does and
/// does not cover.
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
  // A percent string is the documented shape; a bare number is accepted too
  // rather than refused, since nothing here depends on which one a given
  // firmware sends.
  final pct = switch (bat) {
    num n => n.toInt(),
    String s => int.tryParse(s.replaceAll('%', '').trim()),
    _ => null,
  };
  final rawFiles = obj['FileList'];
  final files = rawFiles is String && rawFiles.isNotEmpty
      ? [
          for (final f in rawFiles.split(','))
            if (f.trim().isNotEmpty) f.trim(),
        ]
      : const <String>[];
  // GUARDED, NOT CAST. An open JSON value that turns out not to be a string
  // must fall back to null like every other field here, never throw a
  // TypeError past this function's own null-on-anything-unusable contract —
  // the caller runs this from inside a BLE notification callback.
  final model = obj['Model'];
  final serial = obj['SN'];
  return O2RingInfo(
    batteryPct: pct,
    model: model is String ? model : null,
    serial: serial is String ? serial : null,
    files: files,
  );
}
