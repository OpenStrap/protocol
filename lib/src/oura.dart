// The Oura ring's wire format, as pure functions. No BLE, no Flutter, no
// database — everything here takes bytes and returns values, so the whole of it
// is exercised by `test/oura_test.dart` against real captured records with no
// hardware in the room.
//
// AES-128/ECB auth-response encryption is NOT here: it needs a cipher
// implementation this package deliberately has none of (zero runtime deps).
// It lives with the session that drives this wire format, one layer up.
//
// WHAT IS PROVEN AND WHAT IS NOT. The distinction matters more here than
// anywhere else in this directory, because nobody on this project owns a ring
// (ASSUMPTIONS R6) and a decoder that is confidently wrong is the one failure
// this project treats as worse than an absent number.
//
//   * PROVEN against a real 10,208-record capture: the frame header, the event
//     envelope, the deciseconds timestamp unit, and every branch of
//     [decodeDebugData] below. The fixture in the test file is that capture.
//   * PROVEN by layout plus an independent physiological sanity check: the
//     temperature decoders. centi-degrees Celsius, and a worn ring reads
//     33-35 C.
//   * NOT DECODED AT ALL, on purpose: beat-to-beat intervals, SpO2, the
//     hypnogram, steps, raw PPG. Their layouts are bit-packed and this project
//     has not one byte of any of them. A guessed bit order produces a resting
//     50 bpm read as 100 that passes every plausibility bound it is shown, so
//     those frames are ARCHIVED VERBATIM instead (owner rulings R1-R3: capture
//     everything, decode when someone has the hardware). `raw_archive` is never
//     pruned and `LocalDb.redrivableArchiveReasons` is how they get re-decoded
//     in place later. See the report accompanying this change for the layouts.
//
// TIME IS THE HARD PART, and it is not solved here. An event's envelope carries
// a u32 of DECISECONDS on a clock whose epoch is not Unix and is not documented
// anywhere — 9,391,251 in the capture, which is ~10.9 days, so it is a device
// uptime, not a date. Turning it into a wall-clock second needs an ANCHOR, and
// anchoring is a session concern, so it lives in the adapter and not in here.

import 'dart:typed_data';

/// One frame off the notify characteristic: `[tag u8][len u8][payload…]`.
///
/// `len` counts payload bytes only, so a frame is 2 + len bytes and cannot
/// exceed 257. There is no CRC, no sequence number and no fragmentation: one
/// BLE notification carries exactly one frame, which is why this returns a
/// single frame rather than a list.
class OuraFrame {
  final int tag;
  final Uint8List payload;
  const OuraFrame(this.tag, this.payload);
}

/// Parse one notification. Null when it cannot be a frame at all.
///
/// LENIENT IN ONE DIRECTION ONLY. The ring is known to append trailing bytes
/// past the declared length, so extra bytes are ignored. A declared length
/// LONGER than the buffer is the opposite case and it is a truncated frame —
/// this returns null rather than handing back a short payload that every
/// downstream length check would then treat as a real, complete record.
OuraFrame? parseOuraFrame(List<int> value) {
  if (value.length < 2) return null;
  final len = value[1];
  if (value.length - 2 < len) return null;
  return OuraFrame(value[0], Uint8List.fromList(value.sublist(2, 2 + len)));
}

/// Tags at or above this are history-event frames; below it they are responses
/// to something the host wrote.
const int kOuraFirstEventTag = 0x41;

/// One history event: an envelope timestamp and a type-specific body.
class OuraEvent {
  final int tag;

  /// The ring's own clock, in units of 100 ms. NOT Unix time — see the header.
  final int tsDs;

  final Uint8List body;
  const OuraEvent(this.tag, this.tsDs, this.body);
}

/// The history event carried by [f], or null when [f] is a command response or
/// is too short to carry the 4-byte envelope timestamp.
OuraEvent? parseOuraEvent(OuraFrame f) {
  if (f.tag < kOuraFirstEventTag) return null;
  if (f.payload.length < 4) return null;
  final ts = f.payload.buffer
      .asByteData(f.payload.offsetInBytes)
      .getUint32(0, Endian.little);
  return OuraEvent(f.tag, ts, Uint8List.sublistView(f.payload, 4));
}

// ── event tags this file has something to say about ────────────────────────
/// Wall-clock the ring recorded when the host last set its RTC. The ONLY event
/// that pairs a Unix second with an envelope decisecond, which makes it the one
/// honest anchor between the two clocks.
const int kOuraEvtTimeSync = 0x42;

/// An array of skin-temperature probes.
const int kOuraEvtTemp = 0x46;

/// A single skin-temperature reading.
const int kOuraEvtTempPeriod = 0x69;

/// Firmware diagnostics. Subtype-multiplexed; see [decodeDebugData].
const int kOuraEvtDebugData = 0x61;

/// The frame that terminates one history batch.
const int kOuraTagBatchSummary = 0x11;

/// Unix seconds the ring recorded for an RTC set, or null when the body is not
/// the expected shape.
///
/// UNLIKE EVERYTHING ELSE THIS FILE DECODES, this specific body layout has no
/// real captured [kOuraEvtTimeSync] frame behind it — the direct-u32-LE-Unix
/// reading is the simplest shape consistent with the envelope's own proven
/// 4-byte-LE convention, and the plausibility window below is what stops a
/// wrong reading from silently anchoring a whole sync in the wrong decade
/// rather than refusing outright. Treat a genuinely captured [kOuraEvtTimeSync]
/// body as the thing to check this against first, before trusting it for
/// anything beyond that gate.
int? decodeTimeSync(OuraEvent e) {
  if (e.tag != kOuraEvtTimeSync || e.body.length < 4) return null;
  final v = e.body.buffer
      .asByteData(e.body.offsetInBytes)
      .getUint32(0, Endian.little);
  // A ring whose RTC was never set reports something that is not a date. The
  // window is the same one `sync_policy` uses for the WHOOP: an absolute Unix
  // second in this decade, and nothing else is an anchor.
  return (v >= 1700000000 && v <= 4100000000) ? v : null;
}

/// Skin temperature in degrees Celsius, one entry per probe.
///
/// The wire carries signed 16-bit little-endian CENTI-degrees. Anything outside
/// the sensor part's own operating range is not a temperature and the WHOLE
/// array is refused — a single bad probe means the offsets are wrong, and half
/// a correct array is more dangerous than none.
///
/// Which physical probe each array position is remains unknown, and one of them
/// may be an ambient reference rather than skin. A caller that needs "the" skin
/// temperature must therefore NOT average them.
List<double>? decodeTemperatures(OuraEvent e) {
  if (e.tag != kOuraEvtTemp && e.tag != kOuraEvtTempPeriod) return null;
  if (e.body.length < 2 || e.body.length.isOdd) return null;
  final d = e.body.buffer.asByteData(e.body.offsetInBytes);
  final out = <double>[];
  for (var i = 0; i + 1 < e.body.length; i += 2) {
    final c = d.getInt16(i, Endian.little) / 100.0;
    if (c < -40 || c > 85) return null;
    out.add(c);
  }
  return out;
}

/// One `debug_data` (`0x61`) sub-record.
///
/// Every field is null unless this subtype actually carries it. There is no
/// "unknown" fallback that invents a number: an unrecognised subtype comes back
/// with [subtype] set and everything else null, which is the signal to archive
/// the bytes rather than to interpret them.
class OuraDebugData {
  /// The sub-record type — body byte 0.
  final int subtype;

  /// A firmware diagnostic string, for [kOuraDebugText] only.
  final String? text;

  /// State of charge, percent.
  final int? batteryPct;

  /// Battery terminal voltage, millivolts.
  final int? batteryMv;

  const OuraDebugData(this.subtype, {this.text, this.batteryPct, this.batteryMv});
}

/// Subtype `0x04` — a NUL-free ASCII diagnostic string in the rest of the body.
const int kOuraDebugText = 0x04;

/// Subtype `0x14` — the fuel gauge's periodic sample. ~10 minutes.
const int kOuraDebugFuelGauge = 0x14;

/// Subtype `0x24` — emitted when the state of charge changes. ~1 hour.
const int kOuraDebugBatteryLevel = 0x24;

/// Decode one `debug_data` body. Null when it is not a sub-record at all.
///
/// DISPATCH IS ON THE SUBTYPE BYTE, NOT ON WHETHER THE BODY LOOKS LIKE TEXT,
/// and that is a correction rather than a preference. Testing the body for
/// printability first gets BOTH halves wrong on the real capture:
///
///   * every one of the 63 text records begins with subtype `0x04`, which is
///     itself not a printable byte — so a printability test over the whole body
///     never fires on them and they are lost;
///   * 127 records of subtypes `0x28` and `0x29` are entirely printable-or-NUL
///     binary — so a printability test DOES fire on them, and firmware counters
///     come back as a string of NULs.
///
/// The subtype byte is unambiguous in both directions on that capture: all 63
/// text records are `0x04`, and no non-`0x04` record has a printable NUL-free
/// tail.
OuraDebugData? decodeDebugData(List<int> body) {
  if (body.isEmpty) return null;
  final subtype = body[0];
  switch (subtype) {
    case kOuraDebugText:
      // A diagnostic label with a counter after it, e.g. `ble_tx:full`. Refused
      // outright if any byte is not printable ASCII: a mis-framed record read
      // as text is how control bytes reach a log the user can export.
      if (body.length < 2) return null;
      for (var i = 1; i < body.length; i++) {
        if (body[i] < 0x20 || body[i] > 0x7e) return null;
      }
      return OuraDebugData(subtype,
          text: String.fromCharCodes(body, 1, body.length));

    case kOuraDebugBatteryLevel:
      // [subtype][u8 percent][u16 LE millivolts][optional flags]
      if (body.length < 4) return null;
      final pct = body[1];
      final mv = body[2] | (body[3] << 8);
      if (pct > 100 || !_plausibleCellMv(mv)) return null;
      return OuraDebugData(subtype, batteryPct: pct, batteryMv: mv);

    case kOuraDebugFuelGauge:
      // [subtype][u16 LE charge counter][u16 LE millivolts][…]. The millivolts
      // are the only field cross-checked against another record: this and
      // `0x24` agree to within 3 mV wherever they land near each other in the
      // capture. The remaining fields track charge and load and are left alone
      // — there is no consumer for them and no second source to check them
      // against.
      if (body.length < 5) return null;
      final mv = body[3] | (body[4] << 8);
      if (!_plausibleCellMv(mv)) return null;
      return OuraDebugData(subtype, batteryMv: mv);

    default:
      // Recognised as a sub-record, deliberately not interpreted. The bytes are
      // archived under this subtype; a future decoder finds them by it.
      return OuraDebugData(subtype);
  }
}

/// A single lithium cell, in millivolts, anywhere between flat and full.
///
/// A PHYSICAL bound and not an encoding one: it is true of the chemistry
/// whatever the field width turns out to be, so a decoder reading the wrong two
/// bytes fails it instead of sailing through (ADDING_A_DEVICE 6.3).
bool _plausibleCellMv(int mv) => mv >= 2500 && mv <= 4500;

/// The frame the ring sends to close one history batch.
class OuraBatchSummary {
  /// How many event frames this batch carried.
  final int received;

  /// How many bytes of history the ring still holds. Zero means the drain is
  /// complete — it is the ONLY completion signal on this path.
  final int bytesLeft;

  const OuraBatchSummary(this.received, this.bytesLeft);
}

/// The batch summary carried by [f], or null when [f] is something else.
OuraBatchSummary? parseBatchSummary(OuraFrame f) {
  if (f.tag != kOuraTagBatchSummary || f.payload.length < 6) return null;
  final d = f.payload.buffer.asByteData(f.payload.offsetInBytes);
  // payload[1] is a sleep-analysis progress byte. Read and discarded on
  // purpose: it is progress information and NOT a gate on the drain, and
  // treating it as one stalls a sync that is working.
  return OuraBatchSummary(f.payload[0], d.getUint32(2, Endian.little));
}

// ── outbound frames ────────────────────────────────────────────────────────
// Every builder returns the complete frame including its two header bytes, so
// a caller can only ever hand `link.write` something well-formed.
//
// THE DESTRUCTIVE COMMANDS ARE ABSENT ON PURPOSE, and their absence is the only
// thing stopping them. Nothing at the session layer above this file inspects an
// unframed band's opcode the way the WHOOP dangerous-opcode gate does — this
// ring's frames carry no such gate at all — so this list of builders IS the
// whole defense. The ring has a factory reset, a firmware-update mode, a DFU
// state machine, a flight mode, a manufacturing-mode setter and a bulk-sampler
// channel with an erase operation. There is no builder for any of them here,
// the session that drives this wire format writes nothing it did not get from
// this file, and its own tests assert that no such tag ever reaches the link.
// Adding a builder for one re-opens the hole.

/// Install this phone's 16-byte pairing key on a FACTORY-RESET ring.
///
/// The key goes out in the clear and the command is not authenticated — it
/// cannot be, since it is what creates the credential the authentication
/// handshake then uses. So this is the FIRST thing written on a pairing
/// connection, before any nonce request, and it is the only command in this
/// file that is not preceded by one.
///
/// The ring holds exactly one key and accepts a new one ONLY while it is
/// factory reset, which makes the reset a PRECONDITION of pairing rather than
/// a consequence of it: a ring that is currently onboarded elsewhere has to be
/// reset before this can succeed, and resetting is what frees it. There is no
/// state in which both work, and there is no way to read the installed key
/// back — losing ours costs another reset and nothing more.
///
/// NOT DESTRUCTIVE, and worth saying because it sits next to a family of
/// commands that are. It writes a credential; it erases nothing. Putting the
/// ring INTO the state that accepts one is a separate command that has no
/// builder here and never will (see the block above).
List<int> ouraCmdSetAuthKey(List<int> key) {
  if (key.length != 16) {
    throw ArgumentError('the Oura pairing key is exactly 16 bytes');
  }
  return <int>[0x24, 0x10, ...key];
}

/// The status of a key install: 0 on success, non-zero for a refusal. Null when
/// [f] is not the reply to one.
///
/// A ring that is NOT factory reset is the refusal that matters, and it does
/// not necessarily answer at all — so a caller must treat silence as a refusal
/// too, never as consent. There is no known way to tell the two apart, and
/// guessing that a quiet ring took the key is how a user spends a factory reset
/// and ends up with neither app working.
int? ouraSetAuthKeyResult(OuraFrame f) =>
    (f.tag == 0x25 && f.payload.isNotEmpty) ? f.payload[0] : null;

/// Ask for a fresh authentication challenge.
List<int> ouraCmdAuthNonce() => const <int>[0x2f, 0x01, 0x2b];

/// Answer the challenge. [cipher] is the encrypted nonce, one AES block.
List<int> ouraCmdAuthenticate(List<int> cipher) =>
    <int>[0x2f, 0x01 + cipher.length, 0x2d, ...cipher];

/// Turn the ring's asynchronous notifications on. `0x3f` is all six flags.
List<int> ouraCmdSetNotifyFlags(int flags) => <int>[0x1c, 0x01, flags & 0xff];

/// Set the ring's real-time clock: u64 LE Unix seconds, then a timezone in
/// half-hour steps.
///
/// This is what later produces a [kOuraEvtTimeSync] event, and that event is the
/// only measured bridge between the ring's decisecond counter and a date — so
/// this write is not housekeeping, it is what makes the timestamps meaningful.
List<int> ouraCmdSyncTime(int unixSeconds, {int tzHalfHours = 0}) {
  final b = Uint8List(9);
  b.buffer.asByteData().setUint64(0, unixSeconds, Endian.little);
  b[8] = tzHalfHours & 0xff;
  return <int>[0x12, 0x09, ...b];
}

/// Request up to [maxEvents] history events at or after [startDs].
///
/// [startDs] is a cursor on the ring's own decisecond clock, not a record index
/// and not a byte offset. [flags] is a type filter passed through verbatim; -1
/// asks for every type.
List<int> ouraCmdGetEvents(int startDs, {int maxEvents = 255, int flags = -1}) {
  final b = Uint8List(9);
  final d = b.buffer.asByteData();
  d.setUint32(0, startDs, Endian.little);
  b[4] = maxEvents.clamp(1, 255);
  d.setInt32(5, flags, Endian.little);
  return <int>[0x10, 0x09, ...b];
}

/// The 15-byte challenge in an authentication-nonce reply, or null.
Uint8List? ouraAuthNonce(OuraFrame f) {
  if (f.tag != 0x2f || f.payload.length < 16 || f.payload[0] != 0x2c) {
    return null;
  }
  return Uint8List.sublistView(f.payload, 1, 16);
}

/// The result of an authentication attempt. Null when [f] is not an
/// authentication reply at all.
///
/// The codes, because the REMEDIES differ and a caller that collapses them to
/// "failed" tells the user the wrong thing:
///
///   * `0` — success.
///   * [kOuraAuthWrongKey] — the ring holds a key and it is not ours.
///     Re-pairing means another factory reset.
///   * [kOuraAuthFactoryReset] — the ring holds NO key. It is waiting to be
///     given one, which is [ouraCmdSetAuthKey], not a re-pair of the same key.
///   * [kOuraAuthNotOnboarded] — a key matched but this is not the device the
///     ring was onboarded to.
int? ouraAuthResult(OuraFrame f) {
  if (f.tag != 0x2f || f.payload.length < 2 || f.payload[0] != 0x2e) return null;
  return f.payload[1];
}

/// The ring holds a key and the one presented is not it.
const int kOuraAuthWrongKey = 0x01;

/// The ring holds no key at all — it is factory reset and waiting for one.
const int kOuraAuthFactoryReset = 0x02;

/// Authenticated, but not as the device this ring was onboarded to.
const int kOuraAuthNotOnboarded = 0x03;

/// True when [f] is the ring refusing a command because the session has not
/// authenticated. Distinguishing this from silence is what stops a drain loop
/// spinning against a ring that is simply waiting to be let in.
bool ouraIsAuthRequired(OuraFrame f) =>
    f.tag == 0x2f && f.payload.isNotEmpty && f.payload[0] == 0x2f;
