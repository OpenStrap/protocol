// control.dart — control-plane decoders ported 1:1 from the edge protocol
// records.dart (HELLO / EVENT / COMMAND_RESPONSE / METADATA sync markers +
// decodeFrame dispatch + compact realtime HR). The R24/R10 *sample* decode is
// NOT duplicated here: decodeFrame delegates the R24 branch to the now-native
// Dart parseR24 (records.dart, Source 1). PURE Dart.

import 'dart:typed_data';
import 'band.dart';
import 'constants.dart';
import 'framing.dart';
import 'gen5_records.dart';
import 'records.dart';

// ── little-endian helpers over a byte list ──────────────────────────────────
ByteData _bd(Uint8List b) => b.buffer.asByteData(b.offsetInBytes, b.length);
int u16(Uint8List b, int o) => _bd(b).getUint16(o, Endian.little);
int i16(Uint8List b, int o) => _bd(b).getInt16(o, Endian.little);
int u32(Uint8List b, int o) => _bd(b).getUint32(o, Endian.little);
double f32(Uint8List b, int o) => _bd(b).getFloat32(o, Endian.little);

double _round(double v, int decimals) {
  if (v.isNaN || v.isInfinite) return 0.0;
  final p = _pow10(decimals);
  return (v * p).roundToDouble() / p;
}

double _pow10(int n) {
  double p = 1;
  for (int i = 0; i < n; i++) {
    p *= 10;
  }
  return p;
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

enum GarmentDeviceLocation {
  unknown(0),
  wrist(1),
  bicep(2),
  calf(3),
  sideTorso(4),
  glute(5),
  ankle(7),
  notConclusive(128),
  unknownGarment(160);

  const GarmentDeviceLocation(this.value);
  final int value;

  static GarmentDeviceLocation? fromValue(int value) {
    for (final location in values) {
      if (location.value == value) return location;
    }
    return null;
  }
}

enum BatteryPackType {
  puffin(12),
  penguin(14);

  const BatteryPackType(this.value);
  final int value;

  static BatteryPackType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

class BodyLocationStatusResponse {
  final int revision;
  final int locationRaw;
  final int confidence;
  final int status;

  const BodyLocationStatusResponse({
    required this.revision,
    required this.locationRaw,
    required this.confidence,
    required this.status,
  });

  GarmentDeviceLocation? get location =>
      GarmentDeviceLocation.fromValue(locationRaw);
}

class HighFreqSyncResponse {
  final int opcode;
  const HighFreqSyncResponse(this.opcode);
}

class SelectWristResponse {
  final int revision;
  final Uint8List payload;

  const SelectWristResponse({
    required this.revision,
    required this.payload,
  });
}

class BatteryPackInfoResponse {
  final int revision;
  final bool attached;
  final String identifier;
  final String name;
  final int batteryPackTypeRaw;
  final int statusRaw;

  const BatteryPackInfoResponse({
    required this.revision,
    required this.attached,
    required this.identifier,
    required this.name,
    required this.batteryPackTypeRaw,
    required this.statusRaw,
  });

  BatteryPackType? get batteryPackType =>
      BatteryPackType.fromValue(batteryPackTypeRaw);
}

class RealtimeHrV2 {
  final int revision;
  final int hrBpm;
  final int tsEpoch;
  final int tsSubsecRaw;
  final bool isOffBody;
  final int locationRaw;

  const RealtimeHrV2({
    required this.revision,
    required this.hrBpm,
    required this.tsEpoch,
    required this.tsSubsecRaw,
    required this.isOffBody,
    required this.locationRaw,
  });

  GarmentDeviceLocation? get location =>
      GarmentDeviceLocation.fromValue(locationRaw);
}

// ── Header-only R10 (live HR) — the IMU arrays stay in the raw bytes. ────────
class R10Lite {
  final int tsEpoch; // u32 @[7:11]
  final int hr; // u8 @[17]
  final int counter; // u32 @[3:7]

  /// Beat-to-beat intervals (ms): declared count @[18], `i16` LE from [19].
  ///
  /// Header-ONLY used to mean the R-R block was dropped too. On the historical
  /// ingest path that is permanent: the record commits as decoded (so it is not
  /// archived) and the band is then acked to trim it, so beats that were
  /// physically present in the offloaded bytes had nothing left to recover
  /// them from. Reports what was ACCEPTED, never what the byte declared.
  final List<int> rrIntervalsMs;

  R10Lite(this.tsEpoch, this.hr, this.counter,
      {this.rrIntervalsMs = const []});
}

R10Lite? parseR10Lite(Uint8List inner) {
  if (inner.length < 18) return null;
  return R10Lite(u32(inner, 7), inner[17], u32(inner, 3),
      rrIntervalsMs: _r10Rr(inner));
}

/// Same offsets and the same accept-only-plausible-values discipline the live
/// decoder applies (`live.dart`'s `realtimeRr`, R10 branch).
List<int> _r10Rr(Uint8List inner) {
  if (inner.length < 19) return const [];
  final declared = inner[18];
  if (declared == 0 || declared > kMaxRrPerRecord) return const [];
  final view = ByteData.sublistView(inner);
  final out = <int>[];
  for (var i = 0; i < declared && 19 + 2 * i + 2 <= inner.length; i++) {
    final v = view.getInt16(19 + 2 * i, Endian.little);
    if (v >= kMinRrMs && v <= kMaxRrMs) out.add(v);
  }
  return out;
}

// ── Compact realtime HR (small 0x28 packet body) ─────────────────────────────

/// RR slots the compact 0x28 form can hold: [10] [12] [14] [16], stopping
/// before the `wearing` byte at [18].
///
/// Naming note: these slots have also been described as a
/// "candidate-estimate count, 0..4" plus "four candidate estimates as u16
/// values" with an unstated physiological role — the identical field pair
/// R18 carries (body 2 / body 3..10 = inner 15 / 16..23). The data settles
/// it: the values ARE R-R intervals in milliseconds. Evidence below.
const int _maxRealtimeRr = 4;

class RealtimeHr {
  final int hrBpm;
  final double hrPrecise;
  final List<int> rrMs;
  final bool wearing;
  final int tsRaw;
  RealtimeHr(this.hrBpm, this.hrPrecise, this.rrMs, this.wearing, this.tsRaw);
}

// was reading ts/hr one byte off from the real layout (used to slice off 3
// header bytes before calling this, which put hr at the wrong spot). checked
// against live.dart's realtimeRr/decodeRecord which are already verified
// against the ts parity oracle, and lines up like this instead:
// ts@2 (u32), hr@8 (u8, not u16/256), rr_count@9, rr1@10, rr2@12, wearing@18.
// so this now just takes the whole inner frame, not a pre-sliced body.
//
// Why these slots are read as R-R and not as unnamed "candidate estimates":
//
//  - the value domain is exactly 333..2400 ms, i.e. 60000/180.2 ..
//    60000/25.0 bpm, and nearly every integer in that range occurs. A field
//    clamped to the reciprocal of a physiological HR range at 1 ms
//    resolution is an interval. type-40 shares the same 2400 ms ceiling —
//    one field in two packets.
//  - slot / (60000/HR) sits at a median of ~1.0, with the bulk of slots
//    within a few tens of percent of the co-reported HR's period.
//  - every alternative unit is dead: essentially no slot reads as bpm, as
//    bpm<<8 or as centi-bpm. The "candidate HR estimate" reading is
//    arithmetically impossible.
//  - they are not the HR byte restated: slots rarely equal round(60000/HR)
//    exactly, so they carry beat-level information the smoothed HR byte
//    does not.
//  - the median per-slot value falls as the count rises — more beats in a
//    second means shorter intervals. Repeated estimates of one quantity
//    would not behave like that.
//
// The COUNT byte is NOT "beats in this second": it anti-correlates with HR,
// falling toward zero as HR rises. It is a detector-confidence count — most
// records declare zero, and every slot the band does declare is a valid
// interval (no zeros, none outside kMinRrMs..kMaxRrMs, no non-zero bytes
// past the declared count, so the gate below currently drops nothing).
//
// Consequence for anything computing HRV from these: the series is GAPPED,
// not contiguous. Slots from non-adjacent seconds are not successive beats,
// and a naive RMSSD across them computes far outside the human resting
// range. Window on real adjacency.
RealtimeHr? parseRealtimeHr(Uint8List inner) {
  if (inner.length < 9) return null;
  final ts = u32(inner, 2);
  final hr = inner[8];
  if (hr < 1 || hr > 250) return null;
  final rr = <int>[];
  // a 9-byte packet has ts+hr but nothing past it - inner[9] (rr_count) would
  // be one byte out of bounds. no rr_count byte just means no RR intervals,
  // not "reject this decode" (copilot review caught this, real bug).
  final n = inner.length > 9 ? inner[9] : 0;
  // Read ALL declared intervals, not just the first two — this used to stop
  // after slots 1 and 2, silently discarding beats 3 and 4 that live.dart's
  // realtimeRr returns from the same bytes (fewer beats = a different RMSSD).
  //
  // The wire form has room for exactly four slots, at [10] [12] [14] [16],
  // bounded by the `wearing` byte at [18]. A declared count above that cannot
  // fit the layout, so — like live.dart, which rejects a large count as
  // "wrong offset" — we emit NO intervals rather than reading `wearing` (or
  // whatever follows) as a heartbeat. Values are gated to the same
  // physiological range records.dart uses.
  if (n > 0 && n <= _maxRealtimeRr) {
    for (int i = 0; i < n; i++) {
      final off = 10 + 2 * i;
      if (off + 2 > inner.length) break;
      final v = u16(inner, off);
      if (v >= kMinRrMs && v <= kMaxRrMs) rr.add(v);
    }
  }
  final wearing = inner.length > 18 ? inner[18] == 1 : true;
  return RealtimeHr(hr, hr.toDouble(), rr, wearing, ts);
}

RealtimeHrV2? parseRealtimeHrV2(Uint8List body) {
  if (body.length < 20) return null;
  final revision = body[1];
  if (revision != 2) return null;
  return RealtimeHrV2(
    revision: revision,
    tsEpoch: u32(body, 2),
    tsSubsecRaw: u16(body, 6),
    hrBpm: body[8],
    isOffBody: body[18] == 0,
    locationRaw: body[19],
  );
}

// ── HELLO identity ───────────────────────────────────────────────────────────
class HelloInfo {
  double? batteryPct;

  /// Always null out of [parseHello] — no charging flag has been located in a
  /// real HELLO body. Take charging from the CHARGING_ON/OFF events.
  bool? charging;
  String? serial;
  String? commit;

  /// Always null out of [parseHello] — same story as [charging]. Wear comes
  /// from the WRIST_ON/OFF events (and realtime HR's `wearing` bit).
  bool? wristOn;
  String rawHex;
  HelloInfo({
    this.batteryPct,
    this.charging,
    this.serial,
    this.commit,
    this.wristOn,
    this.rawHex = '',
  });
}

/// The WHOOP 5 (gen5) `GET_HELLO(0x91)` response body — a DIFFERENT opcode and
/// a DIFFERENT layout from gen4's `GET_HELLO_HARVARD(0x23)`/[HelloInfo], so it
/// gets its own type. Unlike gen4 (whose field offsets drift, so it scans by
/// content), the gen5 revision-1 body is a FIXED map read by absolute offset:
/// the on-band producer fills a fixed 104-byte map, and readers consume
/// offsets through byte 103. Offsets below are BODY-relative — the body is the
/// bytes after the 5-byte command-response header, i.e. `payload.sublist(2)`
/// where `payload` is what [parseCommandResponse] hands the opcode branches
/// (payload[0]=echoed req seq, payload[1]=status).
///
/// Revision-1 hello body: 104 semantic bytes at fixed offsets.
class Gen5HelloInfo {
  /// Exact semantic body length the fixed map spans. The three
  /// trailing bytes of a real 107-byte reply are inner-packet alignment pad.
  static const int semanticBodyLen = 104;

  final int helloRevision; // body[0]

  /// body[1..4] u32 LE, integer-divided by 10. **Null when the raw value is
  /// outside 0..100** — a percentage is 0..100 by definition, so anything else
  /// is a mis-read field, and this package's rule is to omit it rather than
  /// report or clamp a number the bytes do not support.
  final int? batteryPct;
  final bool charging; // body[5] bit0
  final int tsSeconds; // body[6..9] u32 LE — whole seconds
  final int tsSubseconds; // body[10..13] u32 LE — 32768 units/s
  final String serial; // body[14..24] NUL-terminated ASCII
  final String commitHex; // body[25..48] → lowercase hex
  final String cpuHex; // body[49..78] → lowercase hex (also the signature)
  final int hardwareFamily; // body[79..82] u32 LE
  final int pcbaRevision; // body[83..86] u32 LE
  final int opticalDiscriminator; // body[87..90] u32 LE — 48..85 ⇒ WHOOP 5
  final int fwMajor; // body[91]
  final int fwMinor; // body[92]
  final int fwBuild; // body[93]
  final int fwUnreleased; // body[94..97] u32 LE
  final int sigprocMajor; // body[98]
  final int sigprocMinor; // body[99]
  final int sigprocPatch; // body[100]
  final bool hrBroadcast; // body[101] — parsed, not a readiness gate
  final bool wristOn; // body[102] == 1
  final int errorByte; // body[103] signed — logged, not a readiness gate
  final String rawHex;

  const Gen5HelloInfo({
    required this.helloRevision,
    required this.batteryPct,
    required this.charging,
    required this.tsSeconds,
    required this.tsSubseconds,
    required this.serial,
    required this.commitHex,
    required this.cpuHex,
    required this.hardwareFamily,
    required this.pcbaRevision,
    required this.opticalDiscriminator,
    required this.fwMajor,
    required this.fwMinor,
    required this.fwBuild,
    required this.fwUnreleased,
    required this.sigprocMajor,
    required this.sigprocMinor,
    required this.sigprocPatch,
    required this.hrBroadcast,
    required this.wristOn,
    required this.errorByte,
    this.rawHex = '',
  });

  /// The optical discriminator selects the WHOOP 5.0 family in the interval
  /// `48 <= value < 86`.
  bool get isWhoop5 => opticalDiscriminator >= 48 && opticalDiscriminator < 86;

  /// [tsSeconds] gated to the plausible unix range, null otherwise.
  ///
  /// The band ships with its RTC unset, and an unset RTC reports a near-1970
  /// epoch through this field as if it were fact. Hello is the primary gen5
  /// clock source, so clock consumers must take THIS read — the raw
  /// [tsSeconds] stays only as the wire truth.
  int? get tsSecondsOrNull => _plausibleUnix(tsSeconds) ? tsSeconds : null;

  /// `major.minor.build.unreleased`, e.g. `50.40.1.0`.
  String get firmwareVersion => '$fwMajor.$fwMinor.$fwBuild.$fwUnreleased';

  /// `major.minor.patch`, e.g. `11.1.0`.
  String get signalProcessorVersion =>
      '$sigprocMajor.$sigprocMinor.$sigprocPatch';

  /// The all-zero serial is an EEPROM-failure signal, not a hard reject on its
  /// own — a readiness gate should still accept it (it passes the
  /// alphanumeric gate). Surfaced so a caller can decide.
  bool get serialLooksEepromFailure =>
      serial.isNotEmpty && serial.split('').every((c) => c == '0');

  /// Parse EXACTLY the response body (no header). Returns null when the body is
  /// shorter than the [semanticBodyLen] the fixed-offset parser needs — a short
  /// body is a failed/foreign reply, never a partially-filled hello — or when
  /// the body does not announce hello revision 1, since every offset below is
  /// revision-1-specific and reading them out of an unknown revision would
  /// invent an identity rather than decode one.
  ///
  /// Callers should additionally gate on the command-response STATUS byte; a
  /// non-success reply leaves the body unpopulated (see [parseCommandResponse]).
  static Gen5HelloInfo? parse(Uint8List body) {
    if (body.length < semanticBodyLen) return null;
    if (body[0] != 1) return null; // revision-1 map only
    String cstr(int start, int end) {
      final sb = StringBuffer();
      for (int i = start; i < end && i < body.length; i++) {
        final c = body[i];
        if (c == 0) break;
        if (c < 0x20 || c >= 0x7F) return '';
        sb.writeCharCode(c);
      }
      return sb.toString();
    }

    final batteryRaw = u32(body, 1) ~/ 10;
    return Gen5HelloInfo(
      helloRevision: body[0],
      batteryPct: (batteryRaw >= 0 && batteryRaw <= 100) ? batteryRaw : null,
      charging: (body[5] & 0x01) != 0,
      tsSeconds: u32(body, 6),
      tsSubseconds: u32(body, 10),
      serial: cstr(14, 25),
      commitHex: _hex(Uint8List.sublistView(body, 25, 49)),
      cpuHex: _hex(Uint8List.sublistView(body, 49, 79)),
      hardwareFamily: u32(body, 79),
      pcbaRevision: u32(body, 83),
      opticalDiscriminator: u32(body, 87),
      fwMajor: body[91],
      fwMinor: body[92],
      fwBuild: body[93],
      fwUnreleased: u32(body, 94),
      sigprocMajor: body[98],
      sigprocMinor: body[99],
      sigprocPatch: body[100],
      hrBroadcast: body[101] != 0,
      wristOn: body[102] == 1,
      errorByte: body[103] >= 128 ? body[103] - 256 : body[103],
      rawHex: _hex(body),
    );
  }
}

/// A battery percentage is 0..100. Anything else is a mis-read field, not a
/// battery level — callers must omit it, never clamp it (a clamp would report
/// a confident 100% for garbage bytes).
bool _validBatteryPct(double pct) => pct.isFinite && pct >= 0.0 && pct <= 100.0;

List<String> _asciiRuns(Uint8List data, int start, int minlen) {
  final runs = <String>[];
  final cur = StringBuffer();
  for (int i = start; i < data.length; i++) {
    final b = data[i];
    if (b >= 0x20 && b < 0x7F) {
      cur.writeCharCode(b);
    } else {
      if (cur.length >= minlen) runs.add(cur.toString());
      cur.clear();
    }
  }
  if (cur.length >= minlen) runs.add(cur.toString());
  return runs;
}

/// Decode the GET_HELLO_HARVARD response *body* (bytes after [0x24,seq,0x23]).
/// Parses by CONTENT (offsets drift across firmware).
HelloInfo parseHello(Uint8List payload) {
  final info = HelloInfo(rawHex: _hex(payload));
  if (payload.length < 10) return info;

  // Battery is a u16 in tenths of a percent whose offset drifts across
  // firmware, so we scan for the first field that could BE one. The upper
  // bound used to be 1009 (= 100.9%), which let an impossible reading through;
  // a percentage is 0..100 by definition, so 1000 is the ceiling. Out of
  // range = not the battery field, keep scanning / leave batteryPct null.
  //
  // The scan starts at payload[2] — the first byte of the response BODY.
  // payload[0] is the echoed request seq and payload[1] the status, and a
  // status of 1 next to a small body byte reads as a perfectly plausible
  // 0.1–76.9%, so starting at 1 reported the status byte as a battery level.
  for (int off = 2; off < 10; off++) {
    if (off + 2 <= payload.length) {
      final v = u16(payload, off);
      if (v >= 10 && v <= 1000) {
        final pct = _round(v / 10.0, 1);
        if (_validBatteryPct(pct)) {
          info.batteryPct = pct;
          break;
        }
      }
    }
  }
  // NO charging / wristOn here. Both used to be read at asserted offsets that
  // the real bodies disprove: payload[5] is the zero high byte of the u32 the
  // battery scan above resolves at [3], so `charging` was structurally always
  // false; payload[116] sits in the all-zero tail of all three captured HELLO
  // bodies, so `wristOn` was always false and overwrote a true learned from the
  // WRIST_ON event. Both stay null — absent, not a fabricated "no". Charging
  // comes from CHARGING_ON/OFF and wear from WRIST_ON/OFF.

  // Serial is a NUL-terminated ASCII token at a FIXED offset in the body:
  // payload[16] (= inner[19]), immediately followed by the 64-char firmware
  // commit hash. Verified on real captures (serial "4C2248092" @16 across builds).
  // We read it at the offset rather than "first printable run from offset 6" —
  // the bytes [0:16] are a volatile binary header (battery, counters, clock) that
  // on some firmware contain printable bytes and made the scan latch onto junk
  // (the "?*" the user saw). The serial is NOT derivable from the advertised name
  // either: that is user-renamable (e.g. "Abdul's WHOOP").
  const serialOffset = 16;
  final s = _cstrAt(payload, serialOffset);
  if (_validSerial(s)) info.serial = s;

  // Commit = the long hex token. It sits right after the serial's NUL, but we
  // locate it by content (first ≥16-char all-hex run) so a small layout shift
  // can't drop it.
  const hexset = '0123456789abcdefABCDEF';
  for (final r in _asciiRuns(payload, serialOffset, 16)) {
    if (r.length >= 16 && r.split('').every((c) => hexset.contains(c))) {
      info.commit = r;
      break;
    }
  }
  return info;
}

/// Read the NUL-terminated ASCII token at [start]. Returns '' if the byte at
/// [start] is non-printable (i.e. there is no clean token there) — so a wrong
/// offset yields nothing rather than garbage.
String _cstrAt(Uint8List b, int start) {
  if (start < 0 || start >= b.length) return '';
  final sb = StringBuffer();
  for (int i = start; i < b.length; i++) {
    final c = b[i];
    if (c == 0) break; // NUL terminator
    if (c < 0x20 || c >= 0x7F) return ''; // non-printable → not a clean token
    sb.writeCharCode(c);
  }
  return sb.toString();
}

/// A WHOOP serial: 6–13 chars, alphanumeric only (no spaces/punctuation).
bool _validSerial(String s) {
  if (s.length < 6 || s.length > 13) return false;
  for (final c in s.codeUnits) {
    final isDigit = c >= 0x30 && c <= 0x39;
    final isUpper = c >= 0x41 && c <= 0x5A;
    final isLower = c >= 0x61 && c <= 0x7A;
    if (!(isDigit || isUpper || isLower)) return false;
  }
  return true;
}

// ── EVENT (0x30) ─────────────────────────────────────────────────────────────
class EventInfo {
  final int eventId;
  final String name;
  final int tsEpoch;

  /// Sub-second remainder of the event timestamp, u16 @ [8], in units of
  /// 1/32768 s (the 32768 Hz RTC crystal). 0 when the frame is too short.
  final int tsSubsec;

  /// The event-specific body — the frame from offset [12] onward. Empty when
  /// the frame carries no body. Kept raw so callers can decode per event id.
  final Uint8List body;

  final Map<String, dynamic> decoded;
  EventInfo(
    this.eventId,
    this.name,
    this.tsEpoch,
    this.decoded, {
    this.tsSubsec = 0,
    Uint8List? body,
  }) : body = body ?? Uint8List(0);
}

/// The declared body of an event-shaped packet. EVENT (0x30) and CONSOLE_LOGS
/// (0x32) share one envelope:
///   `[type][u8 seq][u16 event id][u32 unix][u16 subsec][u16 body len][body…]`
/// The length field at [10] is what bounds the body — a frame can carry
/// padding past it, which used to be handed back to callers as body bytes.
Uint8List _envelopeBody(Uint8List inner) {
  if (inner.length < 12) return Uint8List(0);
  final end = 12 + u16(inner, 10);
  return Uint8List.sublistView(
      inner, 12, end < inner.length ? end : inner.length);
}

/// Event ids whose names and body decodes are pinned on gen5 hardware only.
/// On a gen4 link the same id number may mean something else entirely (gen4's
/// neighbouring 26/27/28 are known, 29 is not), so a gen4 parse keeps these
/// numeric and un-decoded rather than confidently mislabeled.
const Set<int> _kGen5ScopedEventIds = {
  EventId.strapConditionReport,
  EventId.hapticsTerminated,
  EventId.batteryPackInfo,
  EventId.genericFirmwareEvent,
};

EventInfo? parseEvent(
  Uint8List inner, {
  BandProfile profile = BandProfile.gen4,
}) {
  if (inner.length < 4 || inner[0] != PacketType.event) return null;
  final eid = u16(inner, 2);
  final gen5ScopedOut =
      _kGen5ScopedEventIds.contains(eid) && !profile.isGen5;
  final name = gen5ScopedOut ? 'EVENT_$eid' : EventId.name(eid);
  // Timestamp: whole seconds u32 @ [4], sub-seconds u16 @ [8]; the event body
  // begins at [12]. All guarded by length so short frames degrade cleanly.
  final ts = inner.length >= 8 ? u32(inner, 4) : 0;
  final subsec = inner.length >= 10 ? u16(inner, 8) : 0;
  final body = _envelopeBody(inner);
  final dec = <String, dynamic>{};
  switch (eid) {
    case EventId.chargingOn:
    case EventId.chargingOff:
      dec['charging'] = eid == EventId.chargingOn;
      break;
    case EventId.wristOn:
    case EventId.wristOff:
      dec['on_wrist'] = eid == EventId.wristOn;
      break;
    case EventId.batteryPackConnected:
    case EventId.batteryPackRemoved:
      dec['pack_connected'] = eid == EventId.batteryPackConnected;
      break;
    case EventId.doubleTap:
      dec['double_tap'] = true; // no payload beyond event+timestamp, confirmed
      break;
    case EventId.batteryLevel:
      // Byte-verified on a real BATTERY_LEVEL fixture: soc @ body[1] (u16,
      // DECI-percent — divide by 10; this is a DIFFERENT convention from
      // COMMAND_RESPONSE's GET_BATTERY_LEVEL, which is direct-percent on
      // gen5. Don't conflate the two.), battery_mV @ body[5] (u16),
      // charging @ body[9]. Shared across gen4/gen5 — these are
      // inner-relative offsets, identical across generations.
      //
      // Body: [0] revision = 2, [1:5] u32 state-of-charge ×10, [5:9] u32
      // millivolts, [9] charger/pack-attached flag, [10] always 0, then two
      // packed pairs at [11:15] and [15:19]. `charging` used to be read from
      // [10], the byte that is always zero, so it was permanently false.
      if (body.length >= 12) {
        final soc = _round(u16(body, 1) / 10.0, 1);
        if (soc.isFinite && soc >= 0.0 && soc <= 100.0) {
          dec['battery_pct'] = soc;
        }
        dec['battery_mv'] = u16(body, 5);
        dec['charging'] = body[9] != 0;
      }
      break;
    case EventId.strapConditionReport:
      if (gen5ScopedOut) break;
      // Body: page backlog u32 @0; backlog tenths u16/10 @4; state-of-charge
      // tenths u16/10 @6; then three single bytes — flash @8, charging @9,
      // wrist tri-state @10.
      //
      // `condition_pages_behind` is the SAME quantity GET_DATA_RANGE reports
      // as `pages_behind`: a modular PAGE span from trim to write (~15
      // records/page nominal), never a packet or record count. This event
      // volunteers it live, so a host can watch the backlog without polling.
      //
      // Every field is length-gated on its own so a short frame yields the
      // prefix it really carried rather than nothing (or garbage).
      if (body.length >= 4) dec['condition_pages_behind'] = u32(body, 0);
      if (body.length >= 6) {
        dec['condition_backlog'] = _round(u16(body, 4) / 10.0, 1);
      }
      if (body.length >= 8) {
        // Same 0..100 gate as the BATTERY_LEVEL branch: an out-of-range value
        // is not a state of charge, so emit nothing rather than a number a UI
        // would render.
        final soc = _round(u16(body, 6) / 10.0, 1);
        if (soc.isFinite && soc >= 0.0 && soc <= 100.0) {
          dec['condition_soc_pct'] = soc;
        }
      }
      if (body.length >= 9) dec['condition_flash'] = body[8];
      if (body.length >= 10) dec['condition_charging'] = body[9] != 0;
      // Tri-state, and the doc names no mapping for the three values — kept
      // raw rather than guessed into a bool. Deliberately NOT emitted as
      // `on_wrist`: the wear truth comes from WRIST_ON/WRIST_OFF and hello.
      if (body.length >= 11) dec['condition_wrist_state'] = body[10];
      break;
    case EventId.hapticsTerminated:
      if (gen5ScopedOut) break;
      // body[0] revision, body[1] cause. `user_double_tap` is how the wearer
      // dismisses a running alarm — a dismissal and a timeout are different
      // facts, so both the code and its name are surfaced.
      if (body.length >= 2) {
        dec['haptics_revision'] = body[0];
        dec['haptics_termination_code'] = body[1];
        dec['haptics_termination'] = HapticsTermination.name(body[1]);
      }
      break;
    case EventId.batteryPackInfo:
      if (gen5ScopedOut) break;
      // revision @0, BT address 1..6, device name 7..22, battery-level
      // structure 23..24, colourway 25, hardware family 26 — the
      // GET_BATTERY_PACK_INFO(151) content volunteered as an event.
      if (body.length >= 27) {
        dec['pack_revision'] = body[0];
        dec['pack_address'] = _macAddress(body, 1);
        // Only a real printable name is surfaced; an all-NUL field yields
        // nothing rather than an empty-string "name".
        final packName = _printableRun(body, 7, 23);
        if (packName.isNotEmpty) dec['pack_name'] = packName;
        dec['pack_battery_raw'] = u16(body, 23);
        dec['pack_colorway'] = body[25];
        dec['pack_hardware_family'] = body[26];
      }
      break;
    case EventId.genericFirmwareEvent:
      if (gen5ScopedOut) break;
      // body[0] revision, u16 LE sub-id at body[1]. Only sub-id 6
      // (DORSET_DETECTED) has a known name; the rest stay numeric.
      if (body.length >= 3) {
        dec['fw_event_revision'] = body[0];
        final subId = u16(body, 1);
        dec['fw_event_id'] = subId;
        dec['fw_event'] = FirmwareEventId.name(subId);
      }
      break;
    case EventId.highFreqSyncPrompt:
      dec['high_freq_sync'] = 'prompt';
      break;
    case EventId.highFreqSyncEnabled:
      dec['high_freq_sync'] = 'enabled';
      break;
    case EventId.highFreqSyncDisabled:
      dec['high_freq_sync'] = 'disabled';
      break;
    case EventId.bleRealtimeHrOn:
    case EventId.bleRealtimeHrOff:
      // gen5-only confirmation that the realtime HR stream toggle actually
      // took (gen4 has no equivalent confirmation event for this).
      dec['realtime_hr_stream'] = eid == EventId.bleRealtimeHrOn;
      break;
  }
  return EventInfo(eid, name, ts, dec, tsSubsec: subsec, body: body);
}

// ── COMMAND_RESPONSE (0x24) ──────────────────────────────────────────────────
class CmdResponse {
  final int opcode;
  final Map<String, dynamic> decoded;
  CmdResponse(this.opcode, this.decoded);
}

/// Parse a COMMAND_RESPONSE (0x24) frame. [profile] selects generation-
/// specific response-BODY-SHAPE differences for opcodes that are otherwise
/// opcode-identical across gen4/gen5 (per the multiband spec §1.4: shared
/// opcodes, generational differences live in the response shape, not the
/// opcode number). Defaults to gen4 so every existing caller is unchanged.
CmdResponse? parseCommandResponse(Uint8List inner,
    {BandProfile profile = BandProfile.gen4}) {
  if (inner.length < 3 || inner[0] != PacketType.commandResponse) return null;
  final op = inner[2];
  final payload = Uint8List.sublistView(inner, 3);
  final dec = <String, dynamic>{};
  // A response body is preceded by the ECHOED REQUEST SEQ at inner[3] and the
  // STATUS at inner[4] — the two bytes several decoders here already skip past
  // to find their real first body byte.
  //
  // req_seq lets a caller tell WHICH of its outstanding requests a reply
  // belongs to. Without it every response for an opcode is indistinguishable,
  // and a caller awaiting a specific read can be satisfied by an unrelated
  // earlier request's reply — which matters for GET_CLOCK, where the app polls
  // the RTC from several places at once and gates history offload on the answer.
  //
  // NOTE: that the strap echoes back the seq the PHONE sent is the layout this
  // package has always assumed; it is not confirmed against a hardware capture
  // here. Treat a mismatch as "not the reply I awaited", never as an error,
  // and always keep a path that works when the correlation never matches.
  //
  // cmd_status is the strap's verdict: 0 failed, 1 ok, 2 deferred (a real reply
  // follows this one), 3 opcode not implemented. Surfaced so callers can tell
  // "the strap said no" from "the strap said nothing".
  if (inner.length >= 4) dec['req_seq'] = inner[3];
  final status = inner.length >= 5 ? inner[4] : -1;
  if (status >= 0) dec['cmd_status'] = status;
  if (op == Cmd.getBatteryLevel && inner.length >= (profile.isGen5 ? 6 : 7)) {
    // Byte-verified: gen5 returns a DIRECT percent @ inner[5] (u8, e.g.
    // 0x2F=47%) — NOT deci-percent like gen4's u16 LE @[5:7]. Conflating the
    // two would either divide a real gen5 percent by 10 or read half of a
    // gen4 deci-percent as a whole percent.
    if (profile.isGen5) {
      // A failure reply does not populate the body, so the bytes here are
      // stale. Without the status check a leftover value in 0..100 is reported
      // as a confident battery percentage.
      if (status == 1) {
        final pct = inner[5].toDouble();
        if (_validBatteryPct(pct)) dec['battery_pct'] = pct;
      }
    } else {
      final pct = _round(u16(inner, 5) / 10.0, 1);
      // A battery percentage outside 0..100 is not a battery percentage —
      // `ff ff` here used to surface as 6553.5%. Emit nothing rather than a
      // number the UI would render.
      if (_validBatteryPct(pct)) dec['battery_pct'] = pct;
    }
  } else if (op == Cmd.getHelloHarvard) {
    final h = parseHello(payload);
    dec['hello'] = h;
  } else if (op == Cmd.getHello) {
    // gen5's GET_HELLO (0x91) response — a DIFFERENT opcode from gen4's
    // GET_HELLO_HARVARD (0x23) and a DIFFERENT, FIXED layout
    // ([Gen5HelloInfo]). The body is what follows the 5-byte command-response header,
    // i.e. `payload.sublist(2)` (payload[0]=echoed req seq, payload[1]=status).
    //
    // The previous decode read a "device_name" at pay[51] and a 4-byte
    // "fw_version" at pay[93] — but pay[51] (body offset 49) is the 30-byte
    // CPU/signature field, and the firmware version lives at body 91..94
    // (pay[93]==body[91] is the fw MAJOR byte, which is only why the old
    // ==50 gate happened to hold). Both are superseded by the full map.
    //
    // STATUS-GATED, like the battery and clock reads above/below: hello
    // answers PENDING (2) before its terminal result, and FAILURE (0) /
    // UNSUPPORTED (3) are real wire cases. A non-success reply does not
    // populate the body, so its bytes are whatever the buffer held last —
    // parsing them would mint a confident serial, battery and firmware version
    // out of stale memory.
    if (status == 1) {
      final body =
          payload.length >= 2 ? Uint8List.sublistView(payload, 2) : payload;
      final h = Gen5HelloInfo.parse(body);
      if (h != null) dec['gen5_hello'] = h;
      // Compat: the firmware version this branch used to emit was ACCIDENTALLY
      // correct (it read body[91..94], the true major/minor/build/unreleased),
      // so keep the key alive for one release rather than silently returning
      // null to existing callers. `device_name` is deliberately NOT restored —
      // it was the CPU/signature field, i.e. a wrong value.
      if (h != null) {
        dec['fw_version'] = Uint8List.fromList(
            [h.fwMajor, h.fwMinor, h.fwBuild, h.fwUnreleased & 0xFF]);
      }
    }
  } else if (op == Cmd.getAlarmTime && payload.isNotEmpty) {
    // GET_ALARM_TIME echoes whichever alarm form the strap holds, and the
    // epoch offset DIFFERS between them (this package writes both — see
    // cmdSetAlarmSimple / cmdSetAlarm):
    //   0x01  simple, 7 B:  [0x01][u32 epoch][u16 subsec]        → epoch @1
    //   0x04  rich,  20 B:  [0x04][u8 index][u32 epoch][u16 subsec][12 B haptics]
    //                                                             → epoch @2
    // Reading @1 unconditionally decoded the rich form's [index][epoch:3] as
    // the epoch. An unrecognised leading byte is an unknown form: emit no
    // alarm_epoch rather than guessing an offset.
    // The form byte is the first byte of the reply BODY, which starts at
    // payload[2] — payload[0] is the echoed request seq.
    //
    // The revision-4 GET response is pinned:
    //   body[0] revision 04   body[1] ACTIVE flag (exactly 1 = active)
    //   body[2:6] epoch u32 LE   body[6:8] subseconds u16 LE
    // — which confirms the epoch offset used here, and adds the active flag.
    // The response carries no alarm ID; the requested ID selects it.
    final form = payload.length >= 3 ? payload[2] : -1;
    if (form == 0x01 && payload.length >= 7) {
      dec['alarm_epoch'] = u32(payload, 3);
    } else if (form == 0x04 && payload.length >= 8) {
      dec['alarm_epoch'] = u32(payload, 4);
      // "exactly 1 means active" — anything else is not an armed alarm, and is
      // reported as inactive rather than guessed at.
      dec['alarm_active'] = payload[3] == 1;
    }
  } else if (op == Cmd.setAlarmTime || op == Cmd.runAlarm) {
    // Both replies carry a haptics/alarm STATUS at response-body offset 1 —
    // the SET reply is `[revision][status]…` (remaining response bytes are
    // ignored) and the RUN reply is exactly `[02, status]`. Same offset on
    // both, so one branch.
    // The body starts at payload[2], hence payload[3].
    //
    // Deliberately NOT status-gated, unlike the battery/clock/hello reads
    // above: this status arrives in addition to the ordinary outer command
    // result — check both. A FAILURE reply's status byte is the
    // diagnostic — it is where `invalid alarm time` and `invalid alarm ID`
    // actually appear — so dropping it on a non-success outer result would
    // discard the only explanation the strap ever gives.
    //
    // The revision byte at body 0 is read but NOT gated on: it reads 3 for
    // SET and 2 for RUN, and a strap answering with a revision we do not
    // recognise still put a status byte where the status byte goes.
    if (payload.length >= 4) {
      final code = payload[3];
      dec['alarm_status'] = code;
      dec['alarm_status_name'] = AlarmStatus.name(code);
    }
  } else if (op == Cmd.getAdvertisingNameHarvard ||
      op == Cmd.getCustomAdvertisingName) {
    // gen4's 0x4C and gen5's 0x8D (=141) replies share the same shape at the
    // same payload offsets: 141's reply is revision, status, length, name —
    // i.e. length at body[2] (= payload[4]) and ASCII name from body[3]
    // (= payload[5]), exactly where _decodeAdvName already reads them.
    // Without this branch the gen5 bootstrap's final pre-READY read was sent
    // but its reply never decoded.
    dec['strap_name'] = _decodeAdvName(payload);
  } else if (op == Cmd.getClock || op == Cmd.getClockGen5) {
    // Reply bodies (the body starts at payload[2]):
    //   gen4 0x0B: 8 B  [u32 sec][u32 subsec]         → seconds @ payload[2]
    //   gen5 0x93: 7 B  [rev=1][u32 sec][u16 subsec]  → seconds @ payload[3]
    // Read the field; never scan for one that "looks like an epoch". A
    // byte-wise scan matched the straddle at payload[1]
    // ([status][sec b0][sec b1][sec b2]) — which is in range for every
    // current wall-clock time and sits BEFORE the real field, so clock_epoch
    // was essentially never the strap's actual clock.
    final at = op == Cmd.getClockGen5 ? 3 : 2;
    final revOk =
        op != Cmd.getClockGen5 || (payload.length > 2 && payload[2] == 1);
    // Status-gated on gen5 ONLY, matching the battery read a few cases up: a
    // failure reply leaves the body unpopulated, so the bytes at the clock
    // offset are whatever the buffer held last, and an epoch is far worse to
    // guess than a battery percentage — it becomes the reference every alarm is
    // armed against. gen4 is deliberately NOT gated, for the same reason its
    // battery read is not: the status byte is unconfirmed there, and a wrong
    // assumption means clock_epoch is never emitted at all, which fails
    // silently — no stall, no log, just an RTC that never correlates.
    //
    // Keyed on the PROFILE, not the opcode: gen5 reads its clock with the
    // shared GET_CLOCK(11) (physically confirmed — the unverified 147 is
    // deprecated), so gating on `op == getClockGen5` would have quietly dropped
    // this protection the moment the correct opcode started being used.
    final statusOk = !profile.isGen5 || status == 1;
    if (statusOk && revOk && payload.length >= at + 4) {
      final v = u32(payload, at);
      // Emit nothing rather than a guess: a value outside the plausible
      // window means we are not looking at the clock field.
      if (_plausibleUnix(v)) dec['clock_epoch'] = v;
    }
  } else if (op == Cmd.getDataRange) {
    // 65-byte reply body, starting at payload[2] (payload[0] = echoed request
    // seq, payload[1] = status), so every body offset below is +2:
    //   body[0]                        revision = 1
    //   body[1][5][9][13][17][21][25][29]  u32 RawOldPage, ReadPage,
    //     WritePage, TrimPage, WrapCount, TotalPages, UsedRecords, FreeRecords
    //   body[33],[37] (sec, subsec) oldest   body[41],[45] trim
    //   body[49],[53] current read           body[57],[61] newest
    // The old code walked a 4-byte grid from payload[0] looking for plausible
    // epochs; the real seconds sit at payload[35] and payload[59], both ≡ 3
    // (mod 4), so the grid could never land on either and range_oldest /
    // range_newest were never emitted at all.
    final revOk = payload.length > 2 && payload[2] == 1;
    if (revOk && payload.length >= 63) {
      final oldest = u32(payload, 35);
      final newest = u32(payload, 59);
      if (_plausibleUnix(oldest) && _plausibleUnix(newest) && oldest <= newest) {
        dec['range_oldest'] = oldest;
        dec['range_newest'] = newest;
      }
    }
    // Ring-buffer backlog telemetry. The trim page and wrap count are the
    // strap's own view of its ring buffer, which is what separates a stalled
    // offload from an idle one. Degrades safely: implausible values emit
    // nothing at all.
    if (revOk && payload.length >= 35) {
      final writePage = u32(payload, 11);
      final capacity = u32(payload, 23); // TotalPages
      if (capacity > 0 && writePage <= capacity) {
        dec['pages_behind'] = {
          'written': writePage,
          'used': u32(payload, 27), // UsedRecords
          'capacity': capacity,
          'trim_page': u32(payload, 15),
          'wrap_count': u32(payload, 19),
          'free_records': u32(payload, 31),
        };
      }
    }
  } else if (op == Cmd.getBodyLocationAndStatus && payload.length >= 6) {
    // Reply body is [rev][0][0xFF][location]; only the last byte varies. It
    // starts after the response header, i.e. at payload[2] — reading from
    // payload[0] landed on the echoed-seq/status pair, so `locationRaw` was
    // the status byte and resolved to "wrist" on every successful reply.
    dec['body_location_status'] = BodyLocationStatusResponse(
      revision: payload[2],
      locationRaw: payload[5],
      confidence: payload[4], // constant 0xFF on every observed reply
      status: payload[3], // constant 0
    );
  } else if ((op == Cmd.enterHighFreqSync || op == Cmd.exitHighFreqSync)) {
    dec['high_freq_sync'] = HighFreqSyncResponse(op);
  } else if (op == Cmd.selectWrist && payload.length >= 3) {
    dec['select_wrist'] = SelectWristResponse(
      revision: payload[2],
      payload: Uint8List.fromList(payload.sublist(2)),
    );
  } else if (op == Cmd.getBatteryPackInfo && payload.length >= 30) {
    // 28-byte body [rev][attached][id ×6][name ×16][u16][type][status], again
    // starting at payload[2]. Every field was previously read two bytes early,
    // so type/status were reading the two halves of the unnamed u16.
    dec['battery_pack_info'] = BatteryPackInfoResponse(
      revision: payload[2],
      attached: payload[3] == 1,
      identifier: _macAddress(payload, 4),
      name: _batteryPackName(payload),
      batteryPackTypeRaw: payload[28],
      statusRaw: payload[29],
    );
  } else if (op == Cmd.reportVersionInfo) {
    dec['version_info'] = <String, dynamic>{
      'payload_len': payload.length,
      'raw_hex': _hex(payload),
    };
  }
  return CmdResponse(op, dec);
}

/// The six-byte BT address at [start], rendered `aa:bb:cc:dd:ee:ff`. Shared by
/// the GET_BATTERY_PACK_INFO reply and the BATTERY_PACK_INFO(109) event, which
/// carry the same field at different offsets.
String _macAddress(Uint8List b, int start) => b
    .sublist(start, start + 6)
    .map((v) => v.toRadixString(16).padLeft(2, '0'))
    .join(':');

String _batteryPackName(Uint8List payload) {
  return _printableRun(payload, 10, 26);
}

/// Decode the GET_ADVERTISING_NAME response body. Verified layout (real capture):
/// `[hdr 4B][len u8 @4][ASCII name @5 …][NUL padding]`.
///
/// We bound the name with the length byte and keep ONLY printable ASCII — so a
/// name whose length byte is itself printable (≥0x20, i.e. a name ≥32 chars), a
/// missing NUL terminator, or a stray high byte can't leak header/trailing junk
/// into the string (the "?*" the user saw on repeat reads). Falls back to a
/// skip-control-then-printable scan if the header isn't the expected shape.
String _decodeAdvName(Uint8List p) {
  // Primary: length-prefixed at the verified offset.
  if (p.length > 5) {
    final len = p[4];
    if (len > 0 && len <= 20) {
      // strap names are short (SET caps at 20)
      final s = _printableRun(p, 5, 5 + len);
      if (s.isNotEmpty) return s;
    }
  }
  // Fallback: skip leading control bytes, then read the printable run.
  var start = 0;
  while (start < p.length && p[start] < 0x20) {
    start++;
  }
  return _printableRun(p, start, p.length);
}

/// Build a string from [a, b) keeping only printable ASCII, stopping at the first
/// NUL. Drops any byte ≥0x7f (which would otherwise render as "?").
String _printableRun(Uint8List p, int a, int b) {
  final sb = StringBuffer();
  for (var i = a; i < b && i < p.length; i++) {
    final c = p[i];
    if (c == 0) break;
    if (c >= 0x20 && c < 0x7f) sb.writeCharCode(c);
  }
  return sb.toString().trim();
}

// Lower floor for a "this could be a real wall-clock epoch" u32 — kept local so
// the protocol package has no dependency on the app's sync_policy constants. Any
// time after 2023-11 and not absurdly far in the future is acceptable here; the
// app applies the tighter session-relative gate.
const int _minPlausibleUnix = 1700000000; // 2023-11
const int _maxPlausibleUnix = 4102444800; // 2100-01

/// Could [v] be a real wall-clock epoch? Used to sanity-check a field we read
/// at a known offset — never to go looking for one.
bool _plausibleUnix(int v) => v >= _minPlausibleUnix && v <= _maxPlausibleUnix;

// ── METADATA (0x31) sync markers ─────────────────────────────────────────────
class MetaMarker {
  final int sub;
  final String name;
  final int? expectedPacketCount;
  final Uint8List? token; // 8-byte batch token (HistoryEnd only)

  /// The ring buffer's WRAP COUNT — the second u32 of the 8-byte trim token
  /// (`[u32 trim_page][u32 wrap_count]`). It is NOT an identifier the strap
  /// assigns per batch: it only changes when the ring wraps, so consecutive
  /// batches routinely share a value. Named `batchId` for compatibility with
  /// existing callers; treat it as a wrap counter, never as a unique key.
  final int? batchId;

  /// The strap's OWN wall clock at the moment it finished the burst: whole
  /// seconds at inner[3], sub-seconds (1/32768 s) at inner[7]. HistoryEnd only.
  ///
  /// Free on every burst, on exactly the path where clock skew decides whether
  /// records are admitted or deferred — but nothing reads it yet. Null when the
  /// marker is not HistoryEnd or the frame is short.
  final int? strapClockEpoch;
  final int? strapClockSubsec;

  MetaMarker(
    this.sub,
    this.name,
    this.expectedPacketCount,
    this.token,
    this.batchId, {
    this.strapClockEpoch,
    this.strapClockSubsec,
  });
}

/// gen5 offset audit (2026-08 multiband port): parseMetadata's inner-relative
/// offsets below (sub@2, u32@9, 8-byte token@13:21) were ALREADY correct for
/// gen5 without any change — verified against a real gen5 HISTORY_END
/// fixture (meta_type@inner[2]==2, and the spec's independently-quoted
/// "trim_cursor" value 113405 falls out exactly as `u32(inner, 13)`, i.e. the
/// FIRST four bytes of this function's existing `token`). This is the
/// general "gen5's inner-relative offsets are identical to gen4's" fact
/// (§1.5) holding for METADATA too — no gen5-specific branch needed here.
/// (The multiband spec's own worked METADATA/ACK example pair does NOT
/// actually round-trip byte-for-byte against each other despite being
/// presented as a matched pair — an inconsistency in that source material,
/// not in this decoder; don't chase making that specific pair's `token`
/// values equal.)
MetaMarker? parseMetadata(Uint8List inner) {
  if (inner.length < 3 || inner[0] != PacketType.metadata) return null;
  final sub = inner[2];
  String name;
  switch (sub) {
    case SyncMeta.historyStart:
      name = 'HISTORY_START';
      break;
    case SyncMeta.historyEnd:
      name = 'HISTORY_END';
      break;
    case SyncMeta.historyComplete:
      name = 'HISTORY_COMPLETE';
      break;
    default:
      name = 'META_$sub';
  }
  int? expectedPacketCount;
  Uint8List? token;
  int? batchId;
  int? strapClockEpoch;
  int? strapClockSubsec;
  if (sub == SyncMeta.historyEnd && inner.length >= 13) {
    expectedPacketCount = u32(inner, 9);
    // Gated like every other epoch this file emits. A band that boots with an
    // unset RTC puts a small number here, and the consumer for this field is
    // the clock-skew path — forwarding it raw would be the same mistake the
    // scanned clock_epoch was.
    final rawClock = u32(inner, 3);
    if (_plausibleUnix(rawClock)) {
      strapClockEpoch = rawClock;
      strapClockSubsec = u16(inner, 7);
    }
  }
  if (sub == SyncMeta.historyEnd && inner.length >= 21) {
    token =
        Uint8List.fromList(inner.sublist(13, 21)); // the 8 bytes the ACK echoes
    batchId = u32(inner, 17);
  }
  return MetaMarker(sub, name, expectedPacketCount, token, batchId,
      strapClockEpoch: strapClockEpoch, strapClockSubsec: strapClockSubsec);
}

// ── CONSOLE_LOGS (0x32) ──────────────────────────────────────────────────────
//
// A 0x32 packet is an event packet whose event id is 2, so it carries the
// EVENT envelope (see [_envelopeBody]) — not an envelope of its own:
//   record_index u8  @ inner[1]      (the packet seq)
//   event id     u16 @ inner[2:4]    (= 2)
//   unix         u32 @ inner[4:8]
//   subsec       u16 @ inner[8:10]
//   chunk_len    u16 @ inner[10:12]
//   text             @ inner[12 : 12+chunk_len], trailing-NUL-trimmed only
//     (embedded NULs preserved), capped at 2048 chars, CRC-independent.
// This used to read record_index as a u16, which picked up the event id's low
// byte (i.e. `seq | 0x0200`) and wrapped wrongly, and to treat inner[12] as a
// "channel" byte — there is no channel byte, so every chunk's first character
// was reported as one and dropped from the text.
// A real gen5 log line looks like "146552119: BLE_CMD: Command Send
// Historical Data\n" (boot-tick-ms : tag : message).
class ConsoleLogChunk {
  final int recordIndex;
  final int unix;
  final int subsec;
  final int chunkLen;
  final String text;

  const ConsoleLogChunk({
    required this.recordIndex,
    required this.unix,
    required this.subsec,
    required this.chunkLen,
    required this.text,
  });
}

const int _kConsoleLogTextCap = 2048;

/// Trim a TRAILING run of NUL bytes only — embedded NULs (mid-string) are
/// preserved verbatim, since a log line can legitimately contain them before
/// reassembly trims the real terminator. Decodes as Latin-1 (byte-for-byte)
/// rather than UTF-8: firmware log text is not guaranteed valid UTF-8, and a
/// UTF-8 decode failure would drop the whole chunk instead of surfacing
/// whatever bytes are actually there.
String _consoleLogText(Uint8List raw) {
  var end = raw.length;
  while (end > 0 && raw[end - 1] == 0) {
    end--;
  }
  final capped = end > _kConsoleLogTextCap ? _kConsoleLogTextCap : end;
  return String.fromCharCodes(raw.sublist(0, capped));
}

ConsoleLogChunk? parseConsoleLog(Uint8List inner) {
  if (inner.length < 12 || inner[0] != PacketType.consoleLogs) return null;
  return ConsoleLogChunk(
    recordIndex: inner[1],
    unix: u32(inner, 4),
    subsec: u16(inner, 8),
    chunkLen: u16(inner, 10),
    text: _consoleLogText(_envelopeBody(inner)),
  );
}

/// Reassembles console-log text that straddles multiple consecutive frames.
///
/// Per §1.8: "one log line can straddle multiple consecutive record_index
/// frames — reassemble by contiguous index, not by arrival order." Feed
/// chunks as they decode; [flush] returns (and clears) whatever contiguous
/// run has accumulated so far. A gap in `record_index` (a dropped/reordered
/// frame) flushes what's buffered rather than silently splicing unrelated
/// text together.
class ConsoleLogReassembler {
  final StringBuffer _buf = StringBuffer();

  /// A run that a gap ended, waiting to be handed back by the next [flush].
  /// Only the most recent one is held: a caller that ignores a `false` from
  /// [add] and lets a second gap arrive loses the earlier run.
  String? _completed;
  int? _lastIndex;

  /// Feed one decoded chunk. Returns true if it extended the current
  /// contiguous run; false if it started a new one — call [flush] after a
  /// `false` return to get the run the gap ended.
  bool add(ConsoleLogChunk chunk) {
    final contiguous = _lastIndex != null &&
        // record_index is a u8 — allow wraparound at 0xFF, matching the
        // wire's own modulo-256 counter.
        (chunk.recordIndex == (_lastIndex! + 1) & 0xFF);
    if (_lastIndex != null && !contiguous) {
      // The gap ENDS the buffered run — park it for the caller's next flush().
      // This used to just _buf.clear(), which destroyed the run before the
      // caller could ask for it, so a dropped frame ate the line before it.
      if (_buf.isNotEmpty) _completed = _buf.toString();
      _buf.clear();
    }
    _buf.write(chunk.text);
    _lastIndex = chunk.recordIndex;
    return contiguous;
  }

  /// Return the oldest run we are holding. If a gap ended a run, that run comes
  /// back first and the run being built keeps buffering; otherwise this returns
  /// what has accumulated and resets for the next run.
  String flush() {
    final done = _completed;
    if (done != null) {
      _completed = null;
      return done;
    }
    final s = _buf.toString();
    _buf.clear();
    _lastIndex = null;
    return s;
  }
}

// ── decode_frame dispatch (for live UI / logging) ────────────────────────────
class Decoded {
  final String kind;
  final Map<String, dynamic> fields;
  Decoded(this.kind, this.fields);
}

/// Route a parsed frame to the right decoder. Returns a structured Decoded.
/// [profile] selects generation-specific response-shape handling (battery
/// scale, GET_HELLO opcode, historical-record version family); defaults to
/// gen4 so every existing caller is unchanged.
Decoded decodeFrame(Frame frame, {BandProfile profile = BandProfile.gen4}) {
  // A frame that passed CRC but advertises a frame revision this decoder does
  // not understand (see [Frame.frameRevOk]) must NOT be decoded with the rev-1
  // `inner[0]/[1]/[2]` field offsets — surface it instead of silently handing
  // back a body byte as the packet type / opcode.
  if (!frame.frameRevOk) {
    return Decoded('unsupported_frame_rev', {'packet_type': frame.packetType});
  }
  final inner = frame.inner;
  final pt = frame.packetType;
  try {
    switch (pt) {
      case PacketType.commandResponse:
        final r = parseCommandResponse(inner, profile: profile);
        if (r != null) {
          return Decoded('cmd_response', {'opcode': r.opcode, ...r.decoded});
        }
        break;
      case PacketType.event:
        final e = parseEvent(inner, profile: profile);
        if (e != null) {
          // Spread FIRST so the frame-level keys stay authoritative — a
          // future per-event key named `retain_raw` or `event_id` must not
          // be able to clobber them (`retain_raw` decides whether a client
          // keeps a burst-count member, so a collision would silently drop
          // history records).
          return Decoded('event', {
            ...e.decoded,
            'event': e.name,
            'event_id': e.eventId,
            'ts_epoch': e.tsEpoch,
            'retain_raw': true, // history-count member
          });
        }
        // A type-48 frame whose body we cannot parse is STILL a burst count
        // member and still has to be retained — falling through to 'other'
        // would make a client drop it and undercount the burst.
        return Decoded('event_unparsed', {
          'packet_type': pt,
          'retain_raw': true,
        });
      case PacketType.metadata:
        final m = parseMetadata(inner);
        if (m != null) {
          return Decoded('metadata', {'sub': m.name, 'batch_id': m.batchId});
        }
        break;
      case PacketType.consoleLogs:
        final c = parseConsoleLog(inner);
        if (c != null) {
          return Decoded('console_log', {
            'record_index': c.recordIndex,
            'ts_epoch': c.unix,
            'text': c.text,
            'retain_raw': true, // history-count member
          });
        }
        // Same reasoning as the type-48 fall-through above: a console frame we
        // cannot read is still one burst count member.
        return Decoded('console_unparsed', {
          'packet_type': pt,
          'retain_raw': true,
        });
      case PacketType.historicalData:
      case PacketType.realtimeData:
      case PacketType.realtimeRawData:
        return _decodeDataRecord(inner, profile: profile);
      case PacketType.relativePuffinEvents:
      case PacketType.puffinEventsFromStrap:
      case PacketType.relativeBatteryPackConsoleLogs:
        // Battery-pack ("puffin") event/log wrappers. Their bodies are not
        // decoded into fields here, but each complete frame IS a member of the
        // Sensor-HPS history count and must be retained — so give them
        // a named kind (never 'other', which a client would drop) and flag the
        // frame for the client's raw archive + burst-count paths.
        return Decoded('puffin_event', {'packet_type': pt, 'retain_raw': true});
      case PacketType.puffinCommand:
      case PacketType.puffinCommandResponse:
      case PacketType.puffinMetadata:
        // Battery-pack command/response/metadata. Named (not 'other') for the
        // same reason; NOT history-count members.
        return Decoded('puffin', {'packet_type': pt});
    }
  } catch (e) {
    return Decoded('decode_error', {'error': e.toString()});
  }
  return Decoded('other', {'packet_type': pt});
}

Decoded _decodeDataRecord(Uint8List inner,
    {BandProfile profile = BandProfile.gen4}) {
  if (profile.isGen5 &&
      inner.isNotEmpty &&
      inner[0] == PacketType.historicalData) {
    final g = parseGen5Historical(inner);
    if (g != null) {
      return Decoded('gen5_historical', {
        'hist_version': g.histVersion,
        'record_index': g.recordIndex,
        'ts_epoch': g.unix,
        'kind': g.runtimeType.toString(),
      });
    }
    // Declined — a truncated record, or a version we have no decoder for
    // (16/17/22). Stop here. Falling through would hand a gen5 historical frame
    // to the gen4 realtime heuristic below, which for anything under 64 bytes
    // reads inner[8] as a heart rate — that byte is part of the record's own
    // u32 timestamp, so it invents a plausible-looking bpm out of a clock.
    // edge routes historical frames elsewhere and never reaches this, but the
    // decoder must not fabricate for whoever does.
    return Decoded('data_record', {'rec_type': inner.length > 1 ? inner[1] : -1});
  }
  final recType = inner.length > 1 ? inner[1] : -1;
  // Compact realtime stream (small packet).
  if (inner.length < 64) {
    final hr = parseRealtimeHr(inner);
    if (hr != null) {
      return Decoded('realtime_hr', {
        'rec_type': recType,
        'ts_epoch': hr.tsRaw,
        'hr': hr.hrBpm,
        'hr_precise': hr.hrPrecise,
        'rr_ms': hr.rrMs,
        'wearing': hr.wearing,
      });
    }
    return Decoded('realtime_small', {'rec_type': recType});
  }
  // Live R10 (HR + IMU) — surface HR for the live display.
  if (recType == Record.r10) {
    final r = parseR10Lite(inner);
    if (r != null && r.hr > 0) {
      // rr_ms too: parseR10Lite already accepted these beats, and the short
      // realtime-HR branch above emits them — dropping them here silently
      // halved the beat supply of anything reading live R10 through
      // decodeFrame rather than live.dart.
      return Decoded('realtime_hr', {
        'rec_type': recType,
        'hr': r.hr,
        'rr_ms': r.rrIntervalsMs,
        'wearing': true,
      });
    }
  }
  // R24: delegate to the native Dart full-record decoder (Source 1).
  if (recType == Record.r24) {
    final r = parseR24(inner);
    if (r != null) {
      return Decoded('R24_telemetry', {
        'ts_epoch': r.tsEpoch,
        'ts_subsec': r.tsSubsec,
        'counter': r.counter,
        'hr': r.hr,
      });
    }
  }
  return Decoded('data_record', {'rec_type': recType});
}
