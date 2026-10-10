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
//   * NOT DECODED AT ALL, on purpose: steps, motion and raw PPG. Their field
//     names or window lengths are not pinned, so those frames are ARCHIVED
//     VERBATIM (owner rulings R1-R3: capture everything, decode when the
//     layout is known). `raw_archive` is never pruned, so a decoder written
//     later runs over them in place.
//   * KNOWN LAYOUT, NOT VERIFIED HERE: the hypnogram (seen on a Gen 3 only,
//     never on a Ring 4/5), the 5-minute HR/RMSSD pairs, SpO2, beat-to-beat
//     intervals and always-on HR. None of these has met a capture of ours.
//     Every decoder refuses a body its layout does not fit exactly, and a
//     beat interval or a heart rate outside what a heart does is dropped by
//     its caller: a bit order read wrong fails those bounds far more often
//     than it passes them, but not always, which is why the wearable that
//     carries them stays behind its flag (ASSUMPTIONS R6).
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
/// exceed 257. There is no CRC (except on [kOuraEvtExtended]), no sequence
/// number and no fragmentation. One BLE notification can carry SEVERAL frames
/// back to back (the ring bundles history events); [parseOuraFrames] walks them
/// all, [parseOuraFrame] reads only the first.
class OuraFrame {
  final int tag;
  final Uint8List payload;
  const OuraFrame(this.tag, this.payload);
}

/// Parse the FIRST frame of one notification. Null when it cannot be a frame.
///
/// LENIENT IN ONE DIRECTION ONLY. Bytes past the declared length are ignored
/// here (they are the next bundled frame; see [parseOuraFrames]). A declared
/// length LONGER than the buffer is a truncated frame, and this returns null
/// rather than handing back a short payload that every downstream length check
/// would then treat as a real, complete record.
OuraFrame? parseOuraFrame(List<int> value) {
  if (value.length < 2) return null;
  final len = value[1];
  if (value.length - 2 < len) return null;
  return OuraFrame(value[0], Uint8List.fromList(value.sublist(2, 2 + len)));
}

/// Every frame in one notification, in order.
///
/// UNVERIFIED ON HARDWARE. Whether the ring bundles several frames into one
/// notification has not been seen on a real capture, so the app reads one
/// frame per notification ([parseOuraFrame]) and does not call this. It is
/// kept for a capture to check against.
///
/// A truncated last frame ends the walk and is dropped; the frames before it
/// are kept. A standard event ([kOuraFirstEventTag]..[kOuraLastEventTag])
/// declaring more than 18 payload bytes means the bundle is mis-framed, and
/// then NOTHING in it is trusted: the result is empty.
///
/// [kOuraEvtExtended] is the one frame whose byte 1 is not a length: it is
/// `[0xfd][crc8][realTag][len][u64 time][body]`, 4 + len bytes in all. Its
/// payload here is everything after the tag byte; see [parseOuraExtendedEvent].
List<OuraFrame> parseOuraFrames(List<int> v) {
  final out = <OuraFrame>[];
  var off = 0;
  while (off + 2 <= v.length) {
    final tag = v[off];
    final int end;
    if (tag == kOuraEvtExtended) {
      if (off + 4 > v.length) break;
      end = off + 4 + v[off + 3];
    } else {
      final l = v[off + 1];
      if (tag >= kOuraFirstEventTag && tag <= kOuraLastEventTag && l > 18) {
        return const [];
      }
      end = off + 2 + l;
    }
    if (end > v.length) break;
    out.add(OuraFrame(
        tag,
        Uint8List.fromList(
            v.sublist(off + (tag == kOuraEvtExtended ? 1 : 2), end))));
    off = end;
  }
  return out;
}

/// Tags at or above this are history-event frames; below it they are responses
/// to something the host wrote.
const int kOuraFirstEventTag = 0x41;

/// The last standard event tag. Above it only [kOuraEvtExtended] comes from
/// the ring; `0xfe` is an app-side event and never arrives here.
const int kOuraLastEventTag = 0x8f;

/// One history event: an envelope timestamp and a type-specific body.
class OuraEvent {
  final int tag;

  /// The ring's own clock, in units of 100 ms. NOT Unix time — see the header.
  final int tsDs;

  final Uint8List body;
  const OuraEvent(this.tag, this.tsDs, this.body);
}

/// The standard history event carried by [f], or null when [f] is a command
/// response, is outside [kOuraFirstEventTag]..[kOuraLastEventTag], or its
/// payload is outside the 4..18 bytes a standard event has.
///
/// [kOuraEvtExtended] is NOT read here: its stamp is a u64 at a different
/// offset and of a unit this file has not pinned, so it must never reach a
/// decisecond cursor. See [parseOuraExtendedEvent].
OuraEvent? parseOuraEvent(OuraFrame f) {
  if (f.tag < kOuraFirstEventTag || f.tag > kOuraLastEventTag) return null;
  if (f.payload.length < 4 || f.payload.length > 18) return null;
  final ts = f.payload.buffer
      .asByteData(f.payload.offsetInBytes)
      .getUint32(0, Endian.little);
  return OuraEvent(f.tag, ts, Uint8List.sublistView(f.payload, 4));
}

/// The extended event header byte. See [parseOuraFrames].
const int kOuraEvtExtended = 0xfd;

/// One extended event: its real tag, its u64 ring time (unit not pinned
/// here, so NOT deciseconds and never a cursor), and its body.
class OuraExtendedEvent {
  final int tag;
  final int time;
  final Uint8List body;
  const OuraExtendedEvent(this.tag, this.time, this.body);
}

/// The extended event in [f], or null when [f] is not one, its length is out
/// of range (8..251) or its CRC-8 (poly 0x31, init 0xff, over realTag..end)
/// does not match.
OuraExtendedEvent? parseOuraExtendedEvent(OuraFrame f) {
  if (f.tag != kOuraEvtExtended || f.payload.length < 3) return null;
  final p = f.payload; // [crc][realTag][len][u64 time][body]
  final len = p[2];
  if (len < 8 || len > 251 || p.length != 3 + len) return null;
  var crc = 0xff;
  for (var i = 1; i < p.length; i++) {
    crc ^= p[i];
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x31) & 0xff : (crc << 1) & 0xff;
    }
  }
  if (crc != p[0]) return null;
  final d = p.buffer.asByteData(p.offsetInBytes);
  // Two u32 halves, for the same dart2js reason as [ouraCmdSyncTime].
  final time = d.getUint32(3, Endian.little) +
      d.getUint32(7, Endian.little) * 0x100000000;
  return OuraExtendedEvent(p[1], time, Uint8List.sublistView(p, 11));
}

// ── event tags this file has something to say about ────────────────────────
/// The ring started (boot). Body byte 4 carries reset-reason flags; bit 1 set
/// means the decisecond counter restarted, so any origin measured before it
/// belongs to the previous boot. See [ouraRingStartResetsClock].
const int kOuraEvtRingStart = 0x41;

/// Wall-clock the ring recorded when the host last set its RTC. It pairs a Unix
/// second with an envelope decisecond, so it anchors one clock to the other.
const int kOuraEvtTimeSync = 0x42;

/// An array of skin-temperature probes.
const int kOuraEvtTemp = 0x46;

/// First record of a sleep period's summary. A new one starts a new period, so
/// hypnogram pages seen before it belong to the previous night.
const int kOuraEvtSleepSummary1 = 0x49;

/// A single skin-temperature reading.
const int kOuraEvtTempPeriod = 0x69;

/// The ring received a clock set and did NOT apply it. Not an anchor: no
/// decisecond is bridged to a date by it. See [decodeTimeSyncSkipped].
const int kOuraEvtTimeSyncSkipped = 0x85;

/// UNDECODED. No layout is pinned for this tag; it is archived verbatim and
/// is not a hypnogram carrier.
const int kOuraEvtSleepPhaseInformation = 0x4b;

/// Sleep-stage hypnogram carriers: `details` and `data`. Both are numbered
/// pages of one hypnogram buffer (14-byte body: page index, then 52 epochs),
/// and a later page with the same index replaces an earlier one whichever of
/// the two tags carries it.
const int kOuraEvtSleepPhaseDetails = 0x4e;
const int kOuraEvtSleepPhaseData = 0x5a;

/// Firmware diagnostics. Subtype-multiplexed; see [decodeDebugData].
const int kOuraEvtDebugData = 0x61;

/// The frame that terminates one history batch.
const int kOuraTagBatchSummary = 0x11;

/// True when [e] is a ring start whose reset flags say the decisecond counter
/// restarted (body byte 4, bit 1).
bool ouraRingStartResetsClock(OuraEvent e) =>
    e.tag == kOuraEvtRingStart && e.body.length >= 5 && (e.body[4] & 0x02) != 0;

/// Unix seconds the ring recorded for an RTC set, or null when the body is not
/// the expected shape.
///
/// Layout: u64 LE Unix seconds at body[0..8), then an i8 timezone in
/// half-hour steps at body[8]. Only the low u32 is read: it is the whole value
/// until 2106. The date window below stops an unset RTC from anchoring a whole
/// sync in the wrong decade.
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

/// Why a clock set was skipped: 0 unknown, 1 a PPG measurement was running.
const int kOuraSkipReasonUnknown = 0;
const int kOuraSkipReasonPpgMeasuring = 1;

/// A clock set the ring did not apply ([kOuraEvtTimeSyncSkipped]).
class OuraTimeSyncSkipped {
  /// The Unix second the host asked for.
  final int unix;

  /// The timezone the host sent, in half-hour steps (signed).
  final int tzHalfHours;

  /// [kOuraSkipReasonUnknown], [kOuraSkipReasonPpgMeasuring], or another code.
  final int reason;

  const OuraTimeSyncSkipped(this.unix, this.tzHalfHours, this.reason);
}

/// The skipped clock set in [e], or null when [e] is not one, the body is
/// under 10 bytes, or the second is not a date.
///
/// Layout: u64 LE Unix seconds at body[0..8) (low u32 read, see
/// [decodeTimeSync]), i8 timezone in half-hours at body[8], u8 skip reason at
/// body[9].
OuraTimeSyncSkipped? decodeTimeSyncSkipped(OuraEvent e) {
  if (e.tag != kOuraEvtTimeSyncSkipped || e.body.length < 10) return null;
  final d = e.body.buffer.asByteData(e.body.offsetInBytes);
  final v = d.getUint32(0, Endian.little);
  if (v < 1700000000 || v > 4100000000) return null;
  return OuraTimeSyncSkipped(v, d.getInt8(8), e.body[9]);
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
///
/// Length bounds per tag: [kOuraEvtTemp] is 2 to 7 readings (an even 4..14
/// bytes), [kOuraEvtTempPeriod] exactly one (2 bytes). Anything else is a
/// layout this file does not know and is refused.
List<double>? decodeTemperatures(OuraEvent e) {
  if (e.tag != kOuraEvtTemp && e.tag != kOuraEvtTempPeriod) return null;
  final n = e.body.length;
  if (e.tag == kOuraEvtTemp ? (n < 4 || n > 14 || n.isOdd) : n != 2) {
    return null;
  }
  final d = e.body.buffer.asByteData(e.body.offsetInBytes);
  final out = <double>[];
  for (var i = 0; i + 1 < e.body.length; i += 2) {
    final c = d.getInt16(i, Endian.little) / 100.0;
    if (c < -40 || c > 85) return null;
    out.add(c);
  }
  return out;
}

/// One sleep stage as the ring itself staged it. Declaration order is the
/// 2-bit wire code (0 = deep .. 3 = awake).
enum OuraSleepPhase {
  deep,
  light,
  rem,
  awake,
}

/// One hypnogram event: the carrier's header byte and one stage per 30 s epoch.
class OuraSleepPhases {
  /// The page index (0..35) in the night's hypnogram buffer, the same on
  /// `0x4e` and `0x5a`. Not an epoch offset.
  final int header;

  /// Stages in body order, one per 30 s epoch.
  final List<OuraSleepPhase> phases;

  const OuraSleepPhases(this.header, this.phases);
}

/// The hypnogram carried by [e]: a header byte, then 2-bit stage codes packed
/// four to a byte, MSB-first. Null when [e] is not a hypnogram carrier or has
/// no codes. Absolute timing is left to the caller (from [OuraEvent.tsDs]).
/// [kOuraEvtSleepPhaseInformation] is not a carrier and comes back null.
OuraSleepPhases? decodeSleepPhases(OuraEvent e) {
  if (e.tag != kOuraEvtSleepPhaseDetails &&
      e.tag != kOuraEvtSleepPhaseData) {
    return null;
  }
  if (e.body.length < 2) return null;
  final phases = <OuraSleepPhase>[];
  for (var i = 1; i < e.body.length; i++) {
    final b = e.body[i];
    for (final shift in const [6, 4, 2, 0]) {
      phases.add(OuraSleepPhase.values[(b >> shift) & 0x03]);
    }
  }
  return OuraSleepPhases(e.body[0], phases);
}

/// Five-minute heart rate and RMSSD pairs, one per window, oldest first.
const int kOuraEvtHrv = 0x5d;

/// SpO2: a header byte, then one saturation per second.
const int kOuraEvtSpo2 = 0x6f;

/// Six beat-to-beat intervals with their pulse amplitudes, bit-packed.
const int kOuraEvtIbiAmplitude = 0x60;

/// Beat-to-beat intervals with a quality code, two bytes each (newer rings).
const int kOuraEvtGreenIbiQuality = 0x80;

/// Always-on heart rate: a short burst of readings 1920 ms apart.
const int kOuraEvtAohr = 0x86;

/// The seconds between two [kOuraEvtHrv] windows.
const int kOuraHrvWindowSec = 300;

/// The `(bpm, rmssd ms)` pairs of a [kOuraEvtHrv] event, one per
/// [kOuraHrvWindowSec] window in body order, or null when [e] is not one or
/// its body is not whole pairs. A zero is "no reading" in either field and
/// is left for the caller to drop.
List<(int bpm, int rmssdMs)>? decodeHrvPairs(OuraEvent e) {
  if (e.tag != kOuraEvtHrv) return null;
  final b = e.body;
  if (b.isEmpty || b.length.isOdd) return null;
  return [for (var i = 0; i + 1 < b.length; i += 2) (b[i], b[i + 1])];
}

/// The SpO2 percentages of a [kOuraEvtSpo2] event, one per second in body
/// order, or null when [e] is not one, carries no sample, or any sample is
/// over 100: a saturation over 100 % means the layout is wrong, and the
/// whole event is refused rather than half of it trusted. A trailing `0xff`
/// marks a run that continues in the next event and is not a sample; a zero
/// is "no reading", left for the caller.
List<int>? decodeSpo2(OuraEvent e) {
  if (e.tag != kOuraEvtSpo2 || e.body.length < 2) return null;
  var end = e.body.length;
  if (e.body[end - 1] == 0xff) end--;
  if (end < 2) return null;
  final out = e.body.sublist(1, end);
  return out.any((v) => v > 100) ? null : out;
}

/// The six beat-to-beat intervals (ms) of a [kOuraEvtIbiAmplitude] event, in
/// beat order, or null when [e] is not one or its body is not the fixed 14
/// bytes. Each interval is 11 bits: the high 8 in bytes 0..5, the lowest bit
/// in bit 0 of bytes 6..11, and two middle bits packed into bytes 12..13
/// (beat 0 at bits 7..6 of byte 12, beat 1 at bits 5..4, beat 2 at bits
/// 3..2, beat 3 at bits 1..0, beats 4 and 5 at bits 7..6 and 5..4 of byte
/// 13). The amplitudes in bits 7..1 of bytes 6..11 are not read.
List<int>? decodeIbiAmplitude(OuraEvent e) {
  if (e.tag != kOuraEvtIbiAmplitude || e.body.length != 14) return null;
  final b = e.body;
  int mid(int k) => k < 4
      ? (b[12] >> (6 - 2 * k)) & 0x03
      : (b[13] >> (6 - 2 * (k - 4))) & 0x03;
  return [
    for (var k = 0; k < 6; k++) (b[k] << 3) | (mid(k) << 1) | (b[6 + k] & 1),
  ];
}

/// The `(interval ms, quality)` beats of a [kOuraEvtGreenIbiQuality] event,
/// in beat order, or null when [e] is not one or its body is not whole
/// beats. Per beat: interval = byte 0 << 3 | byte 1 bits 2..0; quality =
/// byte 1 bits 4..3, where 1 is a clean beat.
List<(int ibiMs, int quality)>? decodeGreenIbiQuality(OuraEvent e) {
  if (e.tag != kOuraEvtGreenIbiQuality) return null;
  final b = e.body;
  if (b.length < 2 || b.length.isOdd) return null;
  return [
    for (var i = 0; i + 1 < b.length; i += 2)
      ((b[i] << 3) | (b[i + 1] & 0x07), (b[i + 1] >> 3) & 0x03),
  ];
}

/// The quality code of a clean beat in [decodeGreenIbiQuality].
const int kOuraIbiQualityGood = 1;

/// The `(bpm, quality)` readings of a [kOuraEvtAohr] event, 1920 ms apart in
/// body order, or null when [e] is not one or the body is not exactly its
/// declared count of readings: `[flag][offset][count u8][bpm, quality]...`.
/// What the quality code means is not pinned; a zero bpm is "no reading".
List<(int bpm, int quality)>? decodeAohr(OuraEvent e) {
  if (e.tag != kOuraEvtAohr || e.body.length < 3) return null;
  final n = e.body[2];
  if (e.body.length != 3 + 2 * n) return null;
  return [for (var i = 0; i < n; i++) (e.body[3 + 2 * i], e.body[4 + 2 * i])];
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
      // [0] subtype, [1..3) u16 LE state of charge in 8.8 fixed point
      // (percent = raw / 256), [3..5) u16 LE average millivolts, [5..9) i32 LE
      // average current, [9..11) u16 LE remaining capacity, [11..14) signed
      // 24-bit BIG-endian coulomb counter. Only the millivolts are read: they
      // are the one field cross-checked against another record (this and
      // `0x24` agree to within 3 mV wherever they land near each other in the
      // capture). A body too short for the whole layout is not this record.
      if (body.length < 14) return null;
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
///
/// Any summary with at least one payload byte ends the batch. A field the
/// frame is too short to carry is -1 (unknown), never 0.
class OuraBatchSummary {
  /// How many event frames this batch carried.
  final int received;

  /// The ring's sleep-analysis progress. Above zero with [bytesLeft] at zero
  /// means the ring is still producing this night's sleep events: the drain
  /// is not over, it should ask again from the same cursor shortly. -1 when
  /// absent.
  final int sleepAnalysisProgress;

  /// How many bytes of history the ring still holds. Zero means nothing is
  /// left right now; -1 when the frame does not carry it.
  final int bytesLeft;

  const OuraBatchSummary(this.received, this.bytesLeft,
      {this.sleepAnalysisProgress = -1});
}

/// The batch summary carried by [f], or null when [f] is something else.
OuraBatchSummary? parseBatchSummary(OuraFrame f) {
  if (f.tag != kOuraTagBatchSummary || f.payload.isEmpty) return null;
  final p = f.payload;
  return OuraBatchSummary(
    p[0],
    p.length >= 6
        ? p.buffer.asByteData(p.offsetInBytes).getUint32(2, Endian.little)
        : -1,
    sleepAnalysisProgress: p.length >= 2 ? p[1] : -1,
  );
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

/// Key-install status: the ring's factory production-test flags were never
/// set, so it refuses any pairing key. A factory reset does NOT clear this.
const int kOuraSetAuthKeyProductionTestsMissing = 0x05;

/// Ask for a fresh authentication challenge.
List<int> ouraCmdAuthNonce() => const <int>[0x2f, 0x01, 0x2b];

/// Answer the challenge. [cipher] is the encrypted nonce, one AES block.
///
/// Refuses anything but exactly 16 bytes, the same guard [ouraCmdSetAuthKey]
/// applies to the key: the length byte here is `0x01 + cipher.length`, so a
/// wrong-size cipher either emits a malformed frame or — at 255 bytes and
/// above — overflows the length byte outright rather than throwing where the
/// mistake actually is.
List<int> ouraCmdAuthenticate(List<int> cipher) {
  if (cipher.length != 16) {
    throw ArgumentError('the Oura auth proof is exactly one 16-byte AES block');
  }
  return <int>[0x2f, 0x01 + cipher.length, 0x2d, ...cipher];
}

/// Turn the ring's asynchronous notifications on.
///
/// Flags: low battery 0x01, charging completed 0x02, user active 0x04,
/// background sync 0x08, sitting alert 0x10, power state changed 0x20,
/// gesture 0x80, special notification 0x100. 0x40 is unassigned. `0x3f` is
/// the six lowest; all seven one-byte flags are 0xbf. A flag above 0xff needs
/// the two-byte form, `[0x1c, 0x02, u16 LE]`.
List<int> ouraCmdSetNotifyFlags(int flags) => flags > 0xff
    ? <int>[0x1c, 0x02, flags & 0xff, (flags >> 8) & 0xff]
    : <int>[0x1c, 0x01, flags & 0xff];

/// Set the ring's real-time clock: u64 LE Unix seconds, then the local UTC
/// offset in signed half-hour steps (`timeZoneOffset.inMinutes ~/ 30`).
///
/// This is what later produces a [kOuraEvtTimeSync] event, the one measured
/// bridge between the ring's decisecond counter and a date, so this write is
/// not housekeeping, it is what makes the timestamps meaningful. The ring may
/// decline it (for example mid-measurement) and record
/// [kOuraEvtTimeSyncSkipped] instead; [force] asks it not to, and adds a
/// flags byte (bit 0) so the frame is `[0x12, 0x0a, …9 bytes, 0x01]`. Use it
/// only when there is no origin at all.
List<int> ouraCmdSyncTime(int unixSeconds,
    {int tzHalfHours = 0, bool force = false}) {
  final b = Uint8List(force ? 10 : 9);
  final d = b.buffer.asByteData();
  // Two 32-bit halves, not `setUint64`: Dart's web (dart2js) ByteData throws
  // UnsupportedError on the 64-bit accessors — JS numbers have no native
  // 64-bit integer, and the SDK does not emulate one here. A Unix second
  // fits in the low word alone until the year 2106; the high word is written
  // for correctness at the wire's own field width, not because this app
  // expects it to ever be nonzero.
  d.setUint32(0, unixSeconds & 0xffffffff, Endian.little);
  d.setUint32(4, (unixSeconds >> 32) & 0xffffffff, Endian.little);
  b[8] = tzHalfHours & 0xff;
  if (force) b[9] = 0x01;
  return <int>[0x12, b.length, ...b];
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

/// True when [f] is the ring rejecting the command whose request tag is
/// [reqTag] as unsupported: exactly `[0x30, 0x01, reqTag]`.
bool ouraIsUnsupported(OuraFrame f, int reqTag) =>
    f.tag == 0x30 && f.payload.length == 1 && f.payload[0] == reqTag;
