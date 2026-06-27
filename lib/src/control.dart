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

/// 0x28 HR payload: [0:4]ts [4:6]HR u16/256 [6]rr_count [7:9]rr1 [9:11]rr2 [15]wearing.
RealtimeHr? parseRealtimeHr(Uint8List body) {
  if (body.length < 7) return null;
  final ts = u32(body, 0);
  final hrPrecise = u16(body, 4) / 256.0;
  final hr = hrPrecise.round();
  if (hr < 1 || hr > 250) return null;
  final rr = <int>[];
  final n = body[6];
  if (n > 0 && body.length >= 9) {
    final v = u16(body, 7);
    if (v >= 200 && v <= 2500) rr.add(v);
  }
  if (n > 1 && body.length >= 11) {
    final v = u16(body, 9);
    if (v >= 200 && v <= 2500) rr.add(v);
  }
  final wearing = body.length > 15 ? body[15] == 1 : true;
  return RealtimeHr(hr, _round(hrPrecise, 2), rr, wearing, ts);
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

  const hexset = '0123456789abcdefABCDEF';
  for (final r in _asciiRuns(payload, 6, 6)) {
    if (info.serial == null && r.length >= 6 && r.length <= 13) {
      info.serial = r;
    } else if (info.commit == null &&
        r.length >= 16 &&
        r.split('').every((c) => hexset.contains(c))) {
      info.commit = r;
    }
  }
  return info;
}

// ── EVENT (0x30) ─────────────────────────────────────────────────────────────
class EventInfo {
  final int eventId;
  final String name;
  final int tsEpoch;
  final Map<String, dynamic> decoded;
  EventInfo(this.eventId, this.name, this.tsEpoch, this.decoded);
}

EventInfo? parseEvent(Uint8List inner) {
  if (inner.length < 4 || inner[0] != PacketType.event) return null;
  final eid = u16(inner, 2);
  final name = EventId.name(eid);
  final ts = inner.length >= 8 ? u32(inner, 4) : 0;
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
  }
  return EventInfo(eid, name, ts, dec);
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
    int s = 0;
    while (s < payload.length && payload[s] < 0x20) {
      s++;
    }
    final end = payload.indexOf(0, s);
    final nameBytes = payload.sublist(s, end < 0 ? payload.length : end);
    dec['strap_name'] = String.fromCharCodes(nameBytes).trim();
  } else if (op == Cmd.getClock) {
    final c = _firstPlausibleUnix(payload);
    if (c != null) dec['clock_epoch'] = c;
  } else if (op == Cmd.getDataRange) {
    final range = _plausibleUnixRange(payload);
    if (range != null) {
      dec['range_oldest'] = range[0];
      dec['range_newest'] = range[1];
    }
  }
  return CmdResponse(op, dec);
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
  final Uint8List? token; // 8-byte batch token (HistoryEnd only)
  final int? batchId;
  MetaMarker(this.sub, this.name, this.token, this.batchId);
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
  Uint8List? token;
  int? batchId;
  if (sub == SyncMeta.historyEnd && inner.length >= 21) {
    token = Uint8List.fromList(inner.sublist(13, 21)); // the 8 bytes the ACK echoes
    batchId = u32(inner, 17);
  }
  return MetaMarker(sub, name, token, batchId);
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
    final body = inner.length > 3 ? Uint8List.sublistView(inner, 3) : Uint8List(0);
    final hr = parseRealtimeHr(body);
    if (hr != null) {
      return Decoded('realtime_hr', {
        'rec_type': recType,
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
      return Decoded('realtime_hr', {'rec_type': recType, 'hr': r.hr, 'wearing': true});
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
