// The RingConn ring's wire format, as pure functions. No BLE, no Flutter, no
// database — everything here takes bytes and returns values, so the whole of
// it is exercised by `test/ringconn_test.dart` with no hardware in the room.
//
// SM3 IS HERE AND NOT ONE LAYER UP, unlike Oura's AES-128/ECB. Oura's cipher
// needed a runtime dependency this package deliberately has none of; SM3 is a
// published algorithm (GB/T 32905-2016 — the same public-standard footing as
// AES or SHA-256) with no library on pub.dev worth adding a dependency for a
// 64-round compression function, so it is written out below from the standard
// itself rather than imported.
//
// WHAT IS PROVEN AND WHAT IS NOT (nobody on this project owns this hardware):
//
//   * PROVEN: the SM3 compression function against its own published
//     known-answer test vector (`test/ringconn_test.dart`), independent of
//     anything ring-specific — any conformant SM3 implementation reproduces
//     it. The frame trailer conventions, the command byte shapes, and the
//     bulk-page record lengths are exercised by byte-exact fixtures in the
//     same file.
//   * NOT PROVEN, and not attempted: the challenge/MAC/response TRIPLE used
//     to test [ringConnAuthResponse] end-to-end is self-consistent (computed
//     once from this file's own SM3 and pinned so the function cannot drift),
//     not a captured value from a real ring — there is no ring in the room to
//     capture one from. The MAC-recovery fallback branches in
//     [ringConnMacFromSystemId] beyond the forward EUI-64 form are likewise
//     unverified against real hardware.
//   * NOT DECODED AT ALL, ON PURPOSE: every byte inside a bulk-page record.
//     The 47-byte and 23-byte record lengths are structural — enough to slice
//     a page into records and walk the stream — and nothing inside a record
//     is interpreted here. A guessed field layout is how a confidently wrong
//     number reaches a chart; the records are banked verbatim instead, one
//     layer up.
import 'dart:typed_data';

// ── SM3 (GB/T 32905-2016) ───────────────────────────────────────────────────

const List<int> _kSm3Iv = [
  0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, //
  0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
];

int _rotl32(int x, int n) =>
    n == 0 ? (x & 0xffffffff) : (((x << n) | (x >>> (32 - n))) & 0xffffffff);

int _ff(int j, int x, int y, int z) =>
    j < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z));

int _gg(int j, int x, int y, int z) =>
    j < 16 ? (x ^ y ^ z) : ((x & y) | ((~x & 0xffffffff) & z));

int _p0(int x) => x ^ _rotl32(x, 9) ^ _rotl32(x, 17);
int _p1(int x) => x ^ _rotl32(x, 15) ^ _rotl32(x, 23);

/// SM3, the 256-bit digest GB/T 32905-2016 defines. A Merkle–Damgård
/// construction structurally close to SHA-256 — same padding shape, same
/// 32-bit-word block size — with its own boolean functions, permutations and
/// round constants.
///
/// Built from 32-bit words throughout (`& 0xffffffff` after every arithmetic
/// op, `>>>` — zero-fill shift — for every rotate) rather than `ByteData`'s
/// 64-bit accessors, which dart2js does not implement; see [_lenBytes] for the
/// one place a 64-bit quantity (the bit length) has to be built the same way.
Uint8List sm3(List<int> message) {
  final data = <int>[...message, 0x80];
  while (data.length % 64 != 56) {
    data.add(0);
  }
  data.addAll(_lenBytes(message.length * 8));

  var v = List<int>.from(_kSm3Iv);
  for (var block = 0; block < data.length; block += 64) {
    final w = List<int>.filled(68, 0);
    for (var i = 0; i < 16; i++) {
      final o = block + i * 4;
      w[i] = (data[o] << 24) |
          (data[o + 1] << 16) |
          (data[o + 2] << 8) |
          data[o + 3];
    }
    for (var j = 16; j < 68; j++) {
      final x = w[j - 16] ^ w[j - 9] ^ _rotl32(w[j - 3], 15);
      w[j] = (_p1(x) ^ _rotl32(w[j - 13], 7) ^ w[j - 6]) & 0xffffffff;
    }
    final wp = List<int>.filled(64, 0);
    for (var j = 0; j < 64; j++) {
      wp[j] = w[j] ^ w[j + 4];
    }

    var a = v[0], b = v[1], c = v[2], d = v[3];
    var e = v[4], f = v[5], g = v[6], h = v[7];
    for (var j = 0; j < 64; j++) {
      final tj = j < 16 ? 0x79cc4519 : 0x7a879d8a;
      final ss1 =
          _rotl32((_rotl32(a, 12) + e + _rotl32(tj, j % 32)) & 0xffffffff, 7);
      final ss2 = ss1 ^ _rotl32(a, 12);
      final tt1 = (_ff(j, a, b, c) + d + ss2 + wp[j]) & 0xffffffff;
      final tt2 = (_gg(j, e, f, g) + h + ss1 + w[j]) & 0xffffffff;
      d = c;
      c = _rotl32(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rotl32(f, 19);
      f = e;
      e = _p0(tt2);
    }
    v = [
      v[0] ^ a, v[1] ^ b, v[2] ^ c, v[3] ^ d, //
      v[4] ^ e, v[5] ^ f, v[6] ^ g, v[7] ^ h,
    ];
  }

  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (v[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (v[i] >>> 8) & 0xff;
    out[i * 4 + 3] = v[i] & 0xff;
  }
  return out;
}

/// [bitLen] as 8 big-endian bytes, built from two 32-bit halves. Not
/// `ByteData.setUint64`: dart2js's `ByteData` throws `UnsupportedError` on the
/// 64-bit accessors (the same reason `ouraCmdSyncTime` builds a u64 by hand).
/// Every message this file ever hashes is a handful of bytes, so the high
/// word is always zero in practice — written out anyway for correctness at
/// the algorithm's own field width.
List<int> _lenBytes(int bitLen) {
  final hi = (bitLen >>> 32) & 0xffffffff;
  final lo = bitLen & 0xffffffff;
  return [
    for (final w in [hi, lo]) ...[
      (w >>> 24) & 0xff,
      (w >>> 16) & 0xff,
      (w >>> 8) & 0xff,
      w & 0xff,
    ],
  ];
}

// ── MAC recovery ─────────────────────────────────────────────────────────────

/// The ring's 6-byte BLE MAC, decoded from the 8-byte EUI-64 the standard
/// System ID characteristic (`0x2A23`) carries.
///
/// THE FORWARD FORM IS THE PROVEN ONE: an EUI-64 built from a MAC-48 is
/// `OUI(3) ++ FF FE ++ NIC(3)`, so stripping bytes 3-4 and concatenating what
/// is left recovers the original 6 bytes. The other two branches are
/// fallbacks for a stack that hands the characteristic back byte-reversed, or
/// a ring that never inserted the `FF FE` marker at all — neither has been
/// seen against real hardware, and both are here because a MAC this function
/// cannot recover means a session that can never authenticate.
Uint8List ringConnMacFromSystemId(List<int> systemId) {
  if (systemId.length != 8) {
    throw ArgumentError('a System ID (0x2A23) is exactly 8 bytes');
  }
  final b = systemId;
  if (b[3] == 0xff && b[4] == 0xfe) {
    return Uint8List.fromList([b[0], b[1], b[2], b[5], b[6], b[7]]);
  }
  final r = b.reversed.toList();
  if (r[3] == 0xff && r[4] == 0xfe) {
    return Uint8List.fromList([r[0], r[1], r[2], r[5], r[6], r[7]]);
  }
  // No FF FE marker in either direction: some stacks hand back a bare 6-byte
  // MAC padded to 8, and the leading 6 bytes are the MAC in that shape too.
  return Uint8List.fromList(b.sublist(0, 6));
}

/// The 3-byte auth-response tail: `SM3([V, challenge])[29:32]`, where
/// `V = mac[3] ^ mac[4] ^ mac[5]`.
///
/// [challenge] is the single byte the ring's status reply carries — see
/// [parseRingConnFrame] and [kRingConnRespAuth].
Uint8List ringConnAuthResponse(List<int> mac, int challenge) {
  if (mac.length != 6) {
    throw ArgumentError('a RingConn MAC is exactly 6 bytes');
  }
  final v = (mac[3] ^ mac[4] ^ mac[5]) & 0xff;
  final digest = sm3(<int>[v, challenge & 0xff]);
  return Uint8List.sublistView(digest, 29, 32);
}

// ── framing ──────────────────────────────────────────────────────────────────

/// The epoch RingConn's history cursor counts from: 2019-12-31 12:00:00 UTC,
/// as a Unix second. A cursor is `floor(unixNow) - kRingConnEpochOffset`.
const int kRingConnEpochOffset = 1577793600;

/// [unixSeconds] as a RingConn cursor. Do not pass `0xFFFFFFFF` through this —
/// that value is an unverified "skip backlog" path the vendor app itself is
/// never observed to send; opening at "now" (this function, given the current
/// wall-clock second) is the app-faithful behaviour.
int ringConnCursor(int unixSeconds) => unixSeconds - kRingConnEpochOffset;

/// The history channel that carries sleep/overnight records.
const int kRingConnChannelSleep = 0x00;

/// The history channel that carries all-day/awake records.
const int kRingConnChannelAwake = 0x03;

const int kRingConnCmdStatus = 0x01;
const int kRingConnCmdSyncOpen = 0x02;
const int kRingConnCmdFetch = 0x07;
const int kRingConnCmdAckPpg = 0xc7;
const int kRingConnCmdAckActivity = 0xcc;

/// `0x01 ^ 0x80` — the status/auth reply tag.
const int kRingConnRespAuth = 0x81;

/// `0x02 ^ 0x80` — the sync-open reply tag.
const int kRingConnRespSyncOpen = 0x82;

/// `0x07 ^ 0x80` — "nothing more this poll", the ordinary way a fetch answers
/// once a burst is drained.
const int kRingConnRespFetchEmpty = 0x87;

/// A second observed "burst is over" reply with no established meaning beyond
/// that. Treated the same as [kRingConnRespFetchEmpty] and [kRingConnRespStatus]
/// by [ringConnEndsBurst] — never as a bulk page, never a fetch echo.
const int kRingConnRespUnsolicited = 0x10;

/// `0xc7 ^ 0x80` (== `0x47`) — a PPG/optical bulk page. The same tag also
/// answers the [kRingConnCmdAckPpg] "give me the next page" write, since an
/// ACK's reply IS the next page of the same burst.
const int kRingConnRespBulkPpg = 0x47;

/// `0xcc ^ 0x80` (== `0x4c`) — an activity/sleep bulk page. See
/// [kRingConnRespBulkPpg].
const int kRingConnRespBulkActivity = 0x4c;

/// The one reply with NO xor trailer.
const int kRingConnRespStatus = 0x50;

/// Bytes per record in a [kRingConnRespBulkPpg] page.
const int kRingConnPpgRecordLen = 47;

/// Bytes per record in a [kRingConnRespBulkActivity] page.
const int kRingConnActivityRecordLen = 23;

/// One frame off the notify characteristic.
///
/// `respid = command_byte XOR 0x80` for every reply except
/// [kRingConnRespStatus], which carries no trailer at all — [xorValid] is
/// `true` for that one by construction, since there is nothing to check.
/// [payload] never includes the trailer byte.
class RingConnFrame {
  final int respid;
  final Uint8List payload;

  /// Whether the trailing byte is the XOR of every byte before it. LENIENT ON
  /// PURPOSE: a caller decides what to do with an invalid frame (drop it,
  /// still archive the raw bytes) — this file only reports the fact.
  final bool xorValid;

  const RingConnFrame(this.respid, this.payload, this.xorValid);
}

/// Parse one notification. Null when [value] is too short to be a frame at
/// all — one byte cannot carry both a respid and a trailer.
RingConnFrame? parseRingConnFrame(List<int> value) {
  if (value.isEmpty) return null;
  final respid = value[0];
  if (respid == kRingConnRespStatus) {
    return RingConnFrame(respid, Uint8List.fromList(value.sublist(1)), true);
  }
  if (value.length < 2) return null;
  var x = 0;
  for (var i = 0; i < value.length - 1; i++) {
    x ^= value[i];
  }
  final valid = (x & 0xff) == value[value.length - 1];
  return RingConnFrame(
    respid,
    Uint8List.fromList(value.sublist(1, value.length - 1)),
    valid,
  );
}

/// True for a reply tag that carries a bulk page rather than a status reply.
bool ringConnIsBulk(int respid) =>
    respid == kRingConnRespBulkPpg || respid == kRingConnRespBulkActivity;

/// True for a reply that ends the current fetch burst with no page attached.
bool ringConnEndsBurst(int respid) =>
    respid == kRingConnRespFetchEmpty ||
    respid == kRingConnRespUnsolicited ||
    respid == kRingConnRespStatus;

/// One bulk page: how many records the ring still holds after this page
/// (counting down to 0 on the last page of a burst), and the page's records
/// as raw, unsliced-further bytes.
class RingConnBulkPage {
  final int remaining;
  final List<Uint8List> records;
  const RingConnBulkPage(this.remaining, this.records);
}

/// Slice a bulk-page frame's payload into `(remaining, records)`. Null when
/// [f] is not a bulk-page frame ([ringConnIsBulk] is false), the payload is
/// too short to carry the 2-byte header, or the body does not divide evenly
/// into fixed-size records — a page cut across a record boundary is a framing
/// bug, not a short page to salvage part of.
///
/// NOTHING INSIDE A RECORD IS READ HERE. Each record is handed back exactly as
/// received; see this file's own header for why.
RingConnBulkPage? parseRingConnBulkPage(RingConnFrame f) {
  final recordLen = switch (f.respid) {
    kRingConnRespBulkPpg => kRingConnPpgRecordLen,
    kRingConnRespBulkActivity => kRingConnActivityRecordLen,
    _ => null,
  };
  if (recordLen == null) return null;
  if (f.payload.length < 2) return null;
  final remaining = f.payload[1];
  final body = f.payload.length - 2;
  if (body < 0 || body % recordLen != 0) return null;
  final count = body ~/ recordLen;
  final records = <Uint8List>[
    for (var i = 0; i < count; i++)
      Uint8List.sublistView(
        f.payload,
        2 + i * recordLen,
        2 + (i + 1) * recordLen,
      ),
  ];
  return RingConnBulkPage(remaining, records);
}

// ── outbound commands ───────────────────────────────────────────────────────
// `[cmd][sub][payload...][0x00]` — a literal trailing zero, NOT a checksum.
// Appending an XOR trailer here instead produces bytes the ring silently
// drops; that is the opposite convention from a reply, and confusing the two
// is the one mistake that fails with no error to explain it.

/// Ask for a status reply. The first write on every connection: the reply
/// carries the authentication challenge.
List<int> ringConnCmdStatus() => const [kRingConnCmdStatus, 0x00, 0x00];

/// Answer the challenge with the 3-byte [ringConnAuthResponse].
List<int> ringConnCmdAuthResponse(List<int> response) {
  if (response.length != 3) {
    throw ArgumentError('a RingConn auth response is exactly 3 bytes');
  }
  return [
    kRingConnCmdStatus,
    0x01,
    response[0],
    response[1],
    response[2],
    0x00,
  ];
}

/// Open a history drain on [channel] ([kRingConnChannelSleep] or
/// [kRingConnChannelAwake]) at [cursor] — seconds since [kRingConnEpochOffset],
/// NOT a Unix second.
List<int> ringConnCmdSyncOpen(int cursor, int channel) {
  final c = cursor & 0xffffffff;
  return [
    kRingConnCmdSyncOpen,
    0x00,
    (c >>> 24) & 0xff,
    (c >>> 16) & 0xff,
    (c >>> 8) & 0xff,
    c & 0xff,
    channel & 0xff,
    0x01,
    0x00,
  ];
}

/// Ask for the next reply on the channel a [ringConnCmdSyncOpen] opened —
/// a bulk page if one is ready, a burst-ending reply otherwise.
List<int> ringConnCmdFetch() => const [kRingConnCmdFetch, 0x00, 0x00];

/// Pull the next page of the PPG/optical burst a [kRingConnRespBulkPpg] page
/// is mid-way through.
List<int> ringConnCmdAckPpg() => const [kRingConnCmdAckPpg, 0x00, 0x00];

/// Pull the next page of the activity/sleep burst a [kRingConnRespBulkActivity]
/// page is mid-way through.
List<int> ringConnCmdAckActivity() => const [kRingConnCmdAckActivity, 0x00, 0x00];
