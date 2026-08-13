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
  R10Lite(this.tsEpoch, this.hr, this.counter);
}

R10Lite? parseR10Lite(Uint8List inner) {
  if (inner.length < 18) return null;
  return R10Lite(u32(inner, 7), inner[17], u32(inner, 3));
}

// ── Compact realtime HR (small 0x28 packet body) ─────────────────────────────

/// RR slots the compact 0x28 form can hold: [10] [12] [14] [16], stopping
/// before the `wearing` byte at [18].
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
  bool? charging;
  String? serial;
  String? commit;
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
  if (payload.length > 5) info.charging = payload[5] != 0;
  if (payload.length > 116) info.wristOn = payload[116] != 0;

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

EventInfo? parseEvent(Uint8List inner) {
  if (inner.length < 4 || inner[0] != PacketType.event) return null;
  final eid = u16(inner, 2);
  final name = EventId.name(eid);
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
    // GET_HELLO_HARVARD (0x23), with its own byte-verified fields:
    // device_name @ pay[51], fw_version (4 raw bytes) @ pay[93] gated on
    // pay[93] == 50 (the fw major-version byte real captures show as 50 —
    // e.g. "50.38.1.0" — NOT the ASCII character '5' (that would be 53);
    // absent the gate, don't report a fw_version at all).
    //
    // The name is a 30-byte field. pay[16] — where this used to read — is a
    // binary field on gen5, not the name; that offset is gen4's serial slot.
    if (payload.length >= 81) {
      final name = _cstrAt(payload, 51);
      if (name.isNotEmpty) dec['device_name'] = name;
    }
    if (payload.length >= 97 && payload[93] == 50) {
      dec['fw_version'] = Uint8List.fromList(payload.sublist(93, 97));
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
    final form = payload.length >= 3 ? payload[2] : -1;
    if (form == 0x01 && payload.length >= 7) {
      dec['alarm_epoch'] = u32(payload, 3);
    } else if (form == 0x04 && payload.length >= 8) {
      dec['alarm_epoch'] = u32(payload, 4);
    }
  } else if (op == Cmd.getAdvertisingNameHarvard) {
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
    if (revOk && payload.length >= at + 4) {
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
      identifier: _batteryPackId(payload),
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

String _batteryPackId(Uint8List payload) {
  final bytes = payload.sublist(4, 10);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
}

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
  MetaMarker(
    this.sub,
    this.name,
    this.expectedPacketCount,
    this.token,
    this.batchId,
  );
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
  if (sub == SyncMeta.historyEnd && inner.length >= 13) {
    expectedPacketCount = u32(inner, 9);
  }
  if (sub == SyncMeta.historyEnd && inner.length >= 21) {
    token =
        Uint8List.fromList(inner.sublist(13, 21)); // the 8 bytes the ACK echoes
    batchId = u32(inner, 17);
  }
  return MetaMarker(sub, name, expectedPacketCount, token, batchId);
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
  int? _lastIndex;

  /// Feed one decoded chunk. Returns true if it extended the current
  /// contiguous run; false if it started a new one (the old run, if any, was
  /// flushed into the return value of the PREVIOUS [flush] call — callers
  /// should call [flush] after a `false` return to retrieve what came before).
  bool add(ConsoleLogChunk chunk) {
    final contiguous = _lastIndex != null &&
        // record_index is a u8 — allow wraparound at 0xFF, matching the
        // wire's own modulo-256 counter.
        (chunk.recordIndex == (_lastIndex! + 1) & 0xFF);
    if (_lastIndex != null && !contiguous) {
      // Caller must flush() before this chunk's text is appended, or the
      // discontinuity is silently lost. We still start the new run here.
      _buf.clear();
    }
    _buf.write(chunk.text);
    _lastIndex = chunk.recordIndex;
    return contiguous;
  }

  /// Return everything accumulated so far and reset for the next run.
  String flush() {
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
        final e = parseEvent(inner);
        if (e != null) {
          return Decoded('event', {
            'event': e.name,
            'event_id': e.eventId,
            'ts_epoch': e.tsEpoch,
            ...e.decoded
          });
        }
        break;
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
          });
        }
        break;
      case PacketType.historicalData:
      case PacketType.realtimeData:
      case PacketType.realtimeRawData:
        return _decodeDataRecord(inner, profile: profile);
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
      return Decoded(
          'realtime_hr', {'rec_type': recType, 'hr': r.hr, 'wearing': true});
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
