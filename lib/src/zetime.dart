// MyKronoz ZeTime's command envelope — plain functions, no crypto, no key
// exchange. One write characteristic elicits a reply on a separate notify
// characteristic; there is no bonding requirement and no encrypted payload.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one and
// `flutter_blue_plus` has no simulator path, so this is verified by the wire
// layout and by the compiler.
//
// FRAMING AND TWO DEVICE FACTS ONLY. This file parses the envelope and the
// one reply worth surfacing as a vendor fact today: battery level. Step
// count, sleep and heart-rate history are commands this protocol supports and
// this file deliberately does not touch, request, or decode: they are the
// health signals this band has not been hardware-verified for, and a decoder
// for them is not something to guess at from a spec alone.

/// First byte of every frame.
const int kZeTimePreamble = 0x6f;

/// Last byte of every frame.
const int kZeTimeEnd = 0x8f;

/// Action byte (third position): a host-to-device question.
const int kZeTimeActionRequest = 0x70;

/// The one byte written to the ack characteristic after every write to the
/// command characteristic — a fixed acknowledgement token, not a per-command
/// value.
const int kZeTimeAckToken = 0x03;

/// Command byte for a battery-level request/reply.
const int kZeTimeCmdBattery = 0x08;

/// One decoded frame off the wire:
/// `[0x6f][cmd][action][lenLo][lenHi]…payload…[0x8f]`, where the declared
/// length counts the payload bytes only — it equals `payload.length` exactly
/// and does not count the trailing `[0x8f]`.
class ZeTimeFrame {
  final int cmd;
  final int action;
  final List<int> payload;
  const ZeTimeFrame({
    required this.cmd,
    required this.action,
    required this.payload,
  });
}

/// Build a request frame for [cmd]: preamble, command, REQUEST action, and
/// the one-byte declared length the device's own request frames always send
/// (`[0x01, 0x00]`) even though the byte it counts is unused — transcribed
/// rather than guessed at, because a zero-length declaration is a different,
/// untested frame shape.
List<int> zetimeRequestFrame(int cmd) => <int>[
      kZeTimePreamble,
      cmd,
      kZeTimeActionRequest,
      0x01,
      0x00,
      0x00,
      kZeTimeEnd,
    ];

/// Parse one notify-characteristic value as a complete frame. Null when it is
/// too short, does not start with the preamble, declares a zero-length
/// payload (the device never sends one), its declared length does not match
/// the bytes actually delivered, or it does not end on [kZeTimeEnd] — a
/// malformed or still-fragmented notification is dropped rather than guessed
/// at. A payload that splits across two BLE notifications (the device's own
/// behaviour once the payload exceeds 14 bytes) is not reassembled here: every
/// command this file builds declares a payload well under that, so nothing in
/// this file ever exercises that path.
ZeTimeFrame? parseZeTimeFrame(List<int> value) {
  if (value.length < 7) return null;
  if (value[0] != kZeTimePreamble) return null;
  final payloadSize = value[3] | (value[4] << 8);
  if (payloadSize == 0) return null;
  final msgLength = payloadSize + 6;
  if (msgLength != value.length) return null;
  if (value[msgLength - 1] != kZeTimeEnd) return null;
  return ZeTimeFrame(
    cmd: value[1],
    action: value[2],
    payload: value.sublist(5, msgLength - 1),
  );
}

/// Battery level, 0-100, from a battery-command reply. Null when [f] is not a
/// battery reply, carries no level byte, or the byte is outside 0-100 — a
/// single-byte percentage cannot legitimately read above 100, and a value
/// that does is a misidentified reply, not a real reading.
int? zetimeBatteryLevel(ZeTimeFrame f) {
  if (f.cmd != kZeTimeCmdBattery || f.payload.isEmpty) return null;
  final level = f.payload[0];
  return level <= 100 ? level : null;
}
