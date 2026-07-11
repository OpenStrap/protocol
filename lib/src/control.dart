// control.dart — control-plane decoders ported 1:1 from the edge protocol
// records.dart (HELLO / EVENT / COMMAND_RESPONSE / METADATA sync markers +
// decodeFrame dispatch + compact realtime HR). The R24/R10 *sample* decode is
// NOT duplicated here: decodeFrame delegates the R24 branch to the now-native
// Dart parseR24 (records.dart, Source 1). PURE Dart.

import 'dart:typed_data';
import 'constants.dart';
import 'framing.dart';
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
  if (n > 0 && inner.length >= 12) {
    final v = u16(inner, 10);
    if (v >= 200 && v <= 2500) rr.add(v);
  }
  if (n > 1 && inner.length >= 14) {
    final v = u16(inner, 12);
    if (v >= 200 && v <= 2500) rr.add(v);
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

  for (int off = 1; off < 10; off++) {
    if (off + 2 <= payload.length) {
      final v = u16(payload, off);
      if (v >= 10 && v <= 1009) {
        info.batteryPct = _round(v / 10.0, 1);
        break;
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

EventInfo? parseEvent(Uint8List inner) {
  if (inner.length < 4 || inner[0] != PacketType.event) return null;
  final eid = u16(inner, 2);
  final name = EventId.name(eid);
  // Timestamp: whole seconds u32 @ [4], sub-seconds u16 @ [8]; the event body
  // begins at [12]. All guarded by length so short frames degrade cleanly.
  final ts = inner.length >= 8 ? u32(inner, 4) : 0;
  final subsec = inner.length >= 10 ? u16(inner, 8) : 0;
  final body = inner.length > 12
      ? Uint8List.sublistView(inner, 12)
      : Uint8List(0);
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
      dec['double_tap'] = true;
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
  }
  return EventInfo(eid, name, ts, dec, tsSubsec: subsec, body: body);
}

// ── COMMAND_RESPONSE (0x24) ──────────────────────────────────────────────────
class CmdResponse {
  final int opcode;
  final Map<String, dynamic> decoded;
  CmdResponse(this.opcode, this.decoded);
}

CmdResponse? parseCommandResponse(Uint8List inner) {
  if (inner.length < 3 || inner[0] != PacketType.commandResponse) return null;
  final op = inner[2];
  final payload = Uint8List.sublistView(inner, 3);
  final dec = <String, dynamic>{};
  if (op == Cmd.getBatteryLevel && inner.length >= 7) {
    dec['battery_pct'] = _round(u16(inner, 5) / 10.0, 1); // u16 LE @[5:7] / 10
  } else if (op == Cmd.getHelloHarvard) {
    final h = parseHello(payload);
    dec['hello'] = h;
  } else if (op == Cmd.getAlarmTime && payload.length >= 5) {
    dec['alarm_epoch'] = u32(payload, 1);
  } else if (op == Cmd.getAdvertisingNameHarvard) {
    dec['strap_name'] = _decodeAdvName(payload);
  } else if (op == Cmd.getClock) {
    final c = _firstPlausibleUnix(payload);
    if (c != null) dec['clock_epoch'] = c;
  } else if (op == Cmd.getDataRange) {
    final range = _plausibleUnixRange(payload);
    if (range != null) {
      dec['range_oldest'] = range[0];
      dec['range_newest'] = range[1];
    }
  } else if (op == Cmd.getBodyLocationAndStatus && payload.length >= 4) {
    dec['body_location_status'] = BodyLocationStatusResponse(
      revision: payload[0],
      locationRaw: payload[1],
      confidence: payload[2],
      status: payload[3],
    );
  } else if ((op == Cmd.enterHighFreqSync || op == Cmd.exitHighFreqSync)) {
    dec['high_freq_sync'] = HighFreqSyncResponse(op);
  } else if (op == Cmd.selectWrist && payload.isNotEmpty) {
    dec['select_wrist'] = SelectWristResponse(
      revision: payload[0],
      payload: Uint8List.fromList(payload),
    );
  } else if (op == Cmd.getBatteryPackInfo && payload.length >= 28) {
    dec['battery_pack_info'] = BatteryPackInfoResponse(
      revision: payload[0],
      attached: payload[1] == 1,
      identifier: _batteryPackId(payload),
      name: _batteryPackName(payload),
      batteryPackTypeRaw: payload[26],
      statusRaw: payload[27],
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
  final bytes = payload.sublist(2, 8);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
}

String _batteryPackName(Uint8List payload) {
  return _printableRun(payload, 8, 24);
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

/// First u32 LE in [payload] that looks like a real unix epoch — used to read the
/// strap RTC out of a GET_CLOCK response without pinning a firmware-specific
/// offset (the field has drifted across revisions, like HELLO).
int? _firstPlausibleUnix(Uint8List payload) {
  for (int o = 0; o + 4 <= payload.length; o++) {
    final v = u32(payload, o);
    if (v >= _minPlausibleUnix && v <= _maxPlausibleUnix) return v;
  }
  return null;
}

/// [oldest, newest] from the two plausible-unix u32s in a GET_DATA_RANGE response
/// (min and max of all plausible epochs found). Null if fewer than one is present.
List<int>? _plausibleUnixRange(Uint8List payload) {
  final found = <int>[];
  for (int o = 0; o + 4 <= payload.length; o++) {
    final v = u32(payload, o);
    if (v >= _minPlausibleUnix && v <= _maxPlausibleUnix) found.add(v);
  }
  if (found.isEmpty) return null;
  found.sort();
  return [found.first, found.last];
}

// ── METADATA (0x31) sync markers ─────────────────────────────────────────────
class MetaMarker {
  final int sub;
  final String name;
  final int? expectedPacketCount;
  final Uint8List? token; // 8-byte batch token (HistoryEnd only)
  final int? batchId;
  MetaMarker(
    this.sub,
    this.name,
    this.expectedPacketCount,
    this.token,
    this.batchId,
  );
}

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

// ── decode_frame dispatch (for live UI / logging) ────────────────────────────
class Decoded {
  final String kind;
  final Map<String, dynamic> fields;
  Decoded(this.kind, this.fields);
}

/// Route a parsed frame to the right decoder. Returns a structured Decoded.
Decoded decodeFrame(Frame frame) {
  final inner = frame.inner;
  final pt = frame.packetType;
  try {
    switch (pt) {
      case PacketType.commandResponse:
        final r = parseCommandResponse(inner);
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
      case PacketType.historicalData:
      case PacketType.realtimeData:
      case PacketType.realtimeRawData:
        return _decodeDataRecord(inner);
    }
  } catch (e) {
    return Decoded('decode_error', {'error': e.toString()});
  }
  return Decoded('other', {'packet_type': pt});
}

Decoded _decodeDataRecord(Uint8List inner) {
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
