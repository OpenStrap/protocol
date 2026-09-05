// WearFit wire format — the framing spoken by the Howear family of bands
// (models sold as HK8 Ultra, HK8 Pro Max and similar), paired through the
// "WearFit", "WearFit 2.0" or "WearFit Pro" companion app. Bytes only: no
// BLE, no Flutter, no database.
//
// NOTHING HERE HAS MET HARDWARE. Ships EXPERIMENTAL (ASSUMPTIONS R6): this
// file decodes NO physiological signal from this family's frames — only the
// framing needed to hold a session open, read the band's own battery report,
// and bank whatever else it sends. Nothing here turns bytes into a heart
// rate, a step count or a sleep stage.
//
// TRANSPORT is an otherwise-generic Nordic UART Service link (one write
// characteristic, one notify characteristic). A second, separate service
// UUID is advertised for discovery only and carries no characteristics of
// its own.
//
// FRAME, app<->band, one frame per notification/write, little header:
//   [0]   header (0xAB)
//   [1]   reserved — always 0x00
//   [2]   length: byte count from [3] to the end of the frame, i.e.
//         2 + payload.length
//   [3]   0xFF — fixed marker, not part of the opcode space
//   [4]   command opcode
//   [5..] payload
// There is no CRC and no encryption anywhere in this envelope: a command is
// accepted purely on its opcode, and the length field is the only structure
// this file can check a frame against.

import 'dart:typed_data';

const int kWearFitHeader = 0xAB;

/// Battery status, opcode [kWearFitOpBattery].
const int kWearFitOpBattery = 0x91;

/// One parsed frame. Null for anything too short or missing the fixed
/// marker — see [parseWearFitFrame].
class WearFitFrame {
  final int opcode;
  final Uint8List payload;
  const WearFitFrame(this.opcode, this.payload);
}

/// Parse one notification. Null when it cannot be a frame at all: too short,
/// the wrong header, a missing `0xFF` marker, a declared length under 2 (no
/// room for the opcode byte), or a payload longer than the bytes actually
/// delivered.
WearFitFrame? parseWearFitFrame(List<int> value) {
  if (value.length < 5 || value[0] != kWearFitHeader || value[3] != 0xFF) {
    return null;
  }
  final len = value[2];
  if (len < 2) return null;
  final payloadLen = len - 2;
  if (value.length - 5 < payloadLen) return null;
  return WearFitFrame(
    value[4],
    Uint8List.fromList(value.sublist(5, 5 + payloadLen)),
  );
}

/// Build one outbound frame.
///
/// [payload] must leave room for the length byte at [2] (`2 + payload.length`
/// fits in one byte): 253 bytes or fewer.
Uint8List buildWearFitFrame(int opcode, [List<int> payload = const <int>[]]) {
  if (payload.length > 253) {
    throw ArgumentError.value(payload.length, 'payload.length',
        'must be 253 or fewer — the frame length byte cannot hold more');
  }
  final len = 2 + payload.length;
  final out = Uint8List(5 + payload.length);
  out[0] = kWearFitHeader;
  out[1] = 0x00;
  out[2] = len & 0xff;
  out[3] = 0xFF;
  out[4] = opcode & 0xff;
  out.setRange(5, 5 + payload.length, payload);
  return out;
}

/// Ask the band for its current battery status. Documented request shape,
/// not a guess: `[0x80, 0x01]` is the request payload behind the battery
/// reply this file parses below, and asking is a read, not a write of any
/// band state.
Uint8List wearFitCmdGetBattery() => buildWearFitFrame(kWearFitOpBattery, const [0x80, 0x01]);

/// The band's own battery report.
class WearFitBattery {
  /// 0 = not charging, 1 = charging, 2 = fully charged.
  final int chargeState;

  /// 0-100.
  final int percent;

  const WearFitBattery(this.chargeState, this.percent);
}

/// Parse [f] as a battery reply, or null when it is not one. This is device
/// housekeeping, not a physiological reading — nothing about this decode is
/// gated by the family's EXPERIMENTAL status.
WearFitBattery? parseWearFitBattery(WearFitFrame f) {
  if (f.opcode != kWearFitOpBattery || f.payload.length < 3) return null;
  final state = f.payload[1];
  final pct = f.payload[2];
  if (state > 2 || pct > 100) return null;
  return WearFitBattery(state, pct);
}
