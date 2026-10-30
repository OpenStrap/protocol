// Pebble Protocol over PPoGATT (Pebble 2 / 2 SE, BLE client mode): inner
// framing, the minimal phone handshake, data logging, and the health records
// the watch logs.
//
// PPoGATT packet: one header byte, `serial << 3 | command` (0 data, 1 ack,
// 2 reset), then payload. Serials are 5-bit and wrap.
//
// INNER FRAME (spans packets): `u16 BE length (payload only) | u16 BE
// endpoint | payload`.
//
// HANDSHAKE: the watch asks on endpoint 17 (`[0x00]`); the phone answers with
// its version and capabilities. Then the phone sets the time (endpoint 11)
// and asks data logging to report its sessions (endpoint 6778, `[0x84]`).
//
// DATA LOGGING (endpoint 6778, all little-endian after the frame header):
//   0x01 open  `sid | uuid[16] | u32 ts | u32 tag | u8 itemType | u16 itemSize`
//   0x02 data  `sid | u32 itemsLeft | u32 crc | items…`
//   0x03 close `sid`        0x07 timeout `sid`
// Every message is answered ACK `[0x85, sid]` or NACK `[0x86, sid]`; a NACKed
// message is re-sent. An ACKed one is not — the phone owns it from then on.
//
// HEALTH SESSIONS (tag): 81 steps/minute records, 83 sleep, 84 activity
// overlays (sleep / deep sleep), 85 HR (not decoded; HR rides in the v7+
// minute record). Timestamps are Unix seconds.

import 'dart:typed_data';

const int kPebbleEndpointTime = 11;
const int kPebbleEndpointPhoneVersion = 17;
const int kPebbleEndpointDatalog = 6778;

const int kPebbleDatalogOpen = 0x01;
const int kPebbleDatalogData = 0x02;
const int kPebbleDatalogClose = 0x03;
const int kPebbleDatalogTimeout = 0x07;

const int kPebbleTagSteps = 81;
const int kPebbleTagSleep = 83;
const int kPebbleTagOverlay = 84;

const int kPebbleOverlaySleep = 1;
const int kPebbleOverlayDeepSleep = 2;
const int kPebbleOverlayNap = 3;
const int kPebbleOverlayDeepNap = 4;
const int kPebbleOverlayWalk = 5;
const int kPebbleOverlayRun = 6;

// ── framing ──────────────────────────────────────────────────────────────

/// One inner frame: `u16 BE length | u16 BE endpoint | payload`.
List<int> pebbleFrame(int endpoint, List<int> payload) => [
      (payload.length >> 8) & 0xff,
      payload.length & 0xff,
      (endpoint >> 8) & 0xff,
      endpoint & 0xff,
      ...payload,
    ];

/// Splits an inner frame into PPoGATT data packets of at most [maxPacket]
/// bytes (header included), numbering them from [firstSerial].
List<List<int>> pebblePpogattPackets(List<int> frame, int firstSerial,
    {int maxPacket = 20}) {
  // One byte is the header: below 2 a packet carries nothing and the loop
  // below never advances.
  if (maxPacket < 2) throw ArgumentError.value(maxPacket, 'maxPacket');
  final out = <List<int>>[];
  var serial = firstSerial;
  for (var i = 0; i < frame.length; i += maxPacket - 1) {
    final end = i + maxPacket - 1 < frame.length ? i + maxPacket - 1 : frame.length;
    out.add([(serial & 0x1f) << 3, ...frame.sublist(i, end)]);
    serial++;
  }
  return out;
}

/// Reassembles inner frames from consecutive PPoGATT data payloads.
///
/// The inner framing has no sync marker: the only boundary is the length at
/// the head of the buffer. A partial frame left behind by a transport reset,
/// a re-sent packet appended twice, or a skipped packet shifts every later
/// length and endpoint, and the rest of the session misframes (or waits
/// forever on a garbage length). [reset] throws a cut frame away, and
/// [addPacket] keeps re-sent and out-of-order packets out of the buffer.
class PebbleFrameReassembler {
  final List<int> _buf = [];
  int? _lastSerial;

  // Packets taken since the last reset, capped at [_repeatWindow]: a serial
  // behind the last one only counts as a repeat if it was actually taken.
  int _taken = 0;
  static const int _repeatWindow = 16;

  /// Drops any partial frame and forgets the serial sequence. Call it when
  /// the PPoGATT transport resets.
  void reset() {
    _buf.clear();
    _lastSerial = null;
    _taken = 0;
  }

  /// Feeds one whole PPoGATT data packet (header byte included). Only the
  /// next serial in sequence is taken; anything else (a repeat, or a packet
  /// that arrived after one was lost or skipped) is dropped without touching
  /// the buffer. PPoGATT is go-back-N: the watch re-sends every unacked
  /// packet in order from the oldest, so the missing one comes back and the
  /// frame completes. Clearing on a gap instead would make a mid-frame
  /// payload the head of the buffer and misframe everything after it.
  ///
  /// A repeat of a packet already taken returns an empty list, and the caller
  /// must ack it again: the watch only re-sends a packet whose ack it never
  /// saw, and without a fresh ack it keeps re-sending until its retry limit
  /// resets the transport. After 0, 1, 2 with the acks for 1 and 2 lost, the
  /// re-sent 1 is such a repeat even though 2 was taken last. Returns null
  /// only for a packet that has not been taken and is not the next serial;
  /// the caller does not ack it.
  ///
  /// Serials are 5-bit, so "behind" and "ahead" share one space: anything up
  /// to [_repeatWindow] - 1 behind the last taken serial (and actually taken
  /// since the last reset) is a repeat, anything else is unseen.
  List<(int, Uint8List)>? addPacket(List<int> packet) {
    if (packet.isEmpty) return null;
    final serial = (packet[0] >> 3) & 0x1f;
    final last = _lastSerial;
    if (last != null) {
      final behind = (last - serial) & 0x1f;
      if (behind < _repeatWindow && behind < _taken) return const [];
      if (serial != (last + 1) & 0x1f) return null;
    }
    _lastSerial = serial;
    if (_taken < _repeatWindow) _taken++;
    return add(packet.sublist(1));
  }

  /// Feeds one data payload; returns every complete (endpoint, payload).
  List<(int, Uint8List)> add(List<int> payload) {
    _buf.addAll(payload);
    final out = <(int, Uint8List)>[];
    while (_buf.length >= 4) {
      final len = (_buf[0] << 8) | _buf[1];
      if (_buf.length < 4 + len) break;
      final endpoint = (_buf[2] << 8) | _buf[3];
      out.add((endpoint, Uint8List.fromList(_buf.sublist(4, 4 + len))));
      _buf.removeRange(0, 4 + len);
    }
    return out;
  }
}

// ── handshake ────────────────────────────────────────────────────────────

/// The phone-version reply (endpoint 17): response byte, session caps,
/// platform flags, remote OS (Android = 2), app version 2.4.4.2, then the
/// 8-byte little-endian protocol-capability mask.
List<int> pebblePhoneVersionReply() {
  const caps = 0x1 | 0x2 | 0x4 | 0x8 | 0x20 | 0x80 | 0x100 | 0x800 | 0x2000;
  return [
    0x01,
    0xff, 0xff, 0xff, 0xff, // session capabilities
    0x00, 0x00, 0x00, 0x00, // platform flags
    0x00, 0x00, 0x00, 0x02, // remote OS
    0x02, 0x04, 0x04, 0x02, // app version magic, major, minor, patch
    for (var i = 0; i < 8; i++) (caps >> (8 * i)) & 0xff,
  ];
}

/// Set the watch's clock (endpoint 11): UTC seconds, the local UTC offset in
/// minutes (DST included), and a time-zone name (may be empty).
List<int> pebbleSetTimeUtc(DateTime now, {String tzName = ''}) {
  final utc = now.millisecondsSinceEpoch ~/ 1000;
  final offset = now.timeZoneOffset.inMinutes & 0xffff;
  final name = tzName.codeUnits.take(31).toList();
  return [
    0x03,
    (utc >> 24) & 0xff, (utc >> 16) & 0xff, (utc >> 8) & 0xff, utc & 0xff,
    (offset >> 8) & 0xff, offset & 0xff,
    name.length,
    ...name,
  ];
}

const List<int> kPebbleDatalogReportSessions = [0x84];
List<int> pebbleDatalogAck(int sid) => [0x85, sid];
List<int> pebbleDatalogNack(int sid) => [0x86, sid];

// ── data logging ─────────────────────────────────────────────────────────

int _u16(List<int> b, int i) => b[i] | (b[i + 1] << 8);
int _u32(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// A data-logging session as opened by the watch.
class PebbleDatalogSession {
  final int sid;
  final int tag;
  final int itemSize;

  /// Whether the session's app uuid is all zeros: the watch's own health
  /// service. A watch app logging under the same tag has its own uuid, and
  /// its bytes are not health records.
  final bool system;
  const PebbleDatalogSession(this.sid, this.tag, this.itemSize,
      {this.system = true});
}

/// The session announced by an open message, or null if malformed.
PebbleDatalogSession? parsePebbleDatalogOpen(List<int> p) {
  if (p.length < 29 || p[0] != kPebbleDatalogOpen) return null;
  return PebbleDatalogSession(p[1], _u32(p, 22), _u16(p, 27),
      system: p.sublist(2, 18).every((b) => b == 0));
}

/// The items of a data message, or null if malformed or not a whole number
/// of items.
List<Uint8List>? parsePebbleDatalogItems(List<int> p, int itemSize) {
  if (p.length < 10 || p[0] != kPebbleDatalogData || itemSize <= 0) {
    return null;
  }
  final data = p.sublist(10);
  if (data.length % itemSize != 0) return null;
  return [
    for (var i = 0; i < data.length; i += itemSize)
      Uint8List.fromList(data.sublist(i, i + itemSize)),
  ];
}

// ── health records ───────────────────────────────────────────────────────

/// One minute of the watch's health log.
class PebbleMinute {
  final int tsSec;
  final int steps;
  final int orientation;
  final int intensity;
  final int light;

  /// Beats per minute (record version 7+), or null when absent or 0.
  final int? hr;
  const PebbleMinute(
      this.tsSec, this.steps, this.orientation, this.intensity, this.light,
      this.hr);
}

const Set<int> kPebbleStepsVersions = {5, 6, 7, 12, 13, 14};

/// Decodes one steps item: `u16 version | u32 ts | ?u8 | u8 recordLength |
/// u8 recordCount | records`, one record per minute from `ts`. Null for an
/// unknown version or an item cut short of its record count — the caller
/// must not ACK what it cannot read.
List<PebbleMinute>? parsePebbleStepsItem(List<int> b) {
  if (b.length < 9) return null;
  final version = _u16(b, 0);
  if (!kPebbleStepsVersions.contains(version)) return null;
  final ts = _u32(b, 2);
  final recLen = b[7], count = b[8];
  // steps u8 · orientation u8 · intensity u16 · light u8 · flags u8 (v5+) ·
  // resting/active calories, distance cm u16 each (v6+) · HR u8 (v7+) · …
  final need = version >= 7 ? 13 : version >= 6 ? 12 : 6;
  if (recLen < need) return null;
  final out = <PebbleMinute>[];
  for (var r = 0; r < count; r++) {
    final o = 9 + r * recLen;
    // Short of its own count: a cut item, and a caller ACKs what decodes.
    if (o + recLen > b.length) return null;
    final hr = version >= 7 ? b[o + 12] : 0;
    out.add(PebbleMinute(ts + r * 60, b[o], b[o + 1], _u16(b, o + 2), b[o + 4],
        hr == 0 ? null : hr));
  }
  return out;
}

/// One activity overlay: sleep (1), deep sleep (2), nap (3), deep nap (4),
/// walk (5) or run (6).
class PebbleOverlay {
  final int type;
  final int startSec;
  final int durationSec;
  const PebbleOverlay(this.type, this.startSec, this.durationSec);
}

/// Decodes one overlay item: `u16 version | u16 ? | u16 type | u32 offset |
/// u32 start | u32 duration`. Null for an unknown version.
PebbleOverlay? parsePebbleOverlayItem(List<int> b) {
  if (b.length < 18) return null;
  final version = _u16(b, 0);
  if (version != 1 && version != 3) return null;
  return PebbleOverlay(_u16(b, 4), _u32(b, 10), _u32(b, 14));
}
