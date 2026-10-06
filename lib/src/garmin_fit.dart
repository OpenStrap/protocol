// FIT file decoding — the format Garmin watches store health data in. Written
// from the published FIT file format (header, definition and data records,
// base types, compressed timestamps), not from any SDK.
//
// FILE: `u8 headerSize (12|14) | u8 protocol | u16 profile | u32 dataSize |
// ".FIT" | [u16 headerCrc]`, then `dataSize` bytes of records, then a u16 CRC.
//
// RECORD HEADER:
//   bit 7 set   -> compressed-timestamp data record: local type bits 6-5,
//                  time offset bits 4-0 (seconds, rolling over every 32)
//   otherwise   -> bit 6 definition / data, bit 5 developer fields (on a
//                  definition), local type bits 3-0
// DEFINITION: `u8 reserved | u8 arch (0 LE, 1 BE) | u16 global | u8 n |
// n x (u8 field, u8 size, u8 baseType) | [u8 nDev | nDev x 3 bytes]`.
//
// TIME: field 253 is seconds since 1989-12-31T00:00Z (the FIT epoch); every
// timestamp returned here is already Unix seconds.

import 'dart:typed_data';

/// Seconds between the Unix epoch and the FIT epoch.
const int kFitEpochOffset = 631065600;

const int kFitMsgFileId = 0;
const int kFitMsgMonitoring = 55;
const int kFitMsgMonitoringHrData = 211;
const int kFitMsgStressLevel = 227;
const int kFitMsgSpo2Data = 269;
const int kFitMsgSleepLevel = 275;
const int kFitMsgRespirationRate = 297;
const int kFitMsgHrvStatusSummary = 370;

/// One decoded data message: its global number, its fields by field number
/// (scalars as num, arrays as List, strings as String; invalid values are
/// absent), and its timestamp in Unix seconds when it has one.
class FitMessage {
  final int global;
  final Map<int, Object> fields;
  final int? timestamp;
  const FitMessage(this.global, this.fields, this.timestamp);

  num? num_(int field) {
    final v = fields[field];
    return v is num ? v : null;
  }
}

class _Field {
  final int num, size, base;
  const _Field(this.num, this.size, this.base);
}

class _Def {
  final int global;
  final Endian endian;
  final List<_Field> fields;
  final int devBytes;
  const _Def(this.global, this.endian, this.fields, this.devBytes);
}

// Base type (low 5 bits) -> (size, signed, float, invalid, isZ).
const List<(int, bool, bool, int)> _bases = [
  (1, false, false, 0xff), // 0 enum
  (1, true, false, 0x7f), // 1 sint8
  (1, false, false, 0xff), // 2 uint8
  (2, true, false, 0x7fff), // 3 sint16
  (2, false, false, 0xffff), // 4 uint16
  (4, true, false, 0x7fffffff), // 5 sint32
  (4, false, false, 0xffffffff), // 6 uint32
  (1, false, false, 0), // 7 string
  (4, false, true, 0), // 8 float32
  (8, false, true, 0), // 9 float64
  (1, false, false, 0), // 10 uint8z
  (2, false, false, 0), // 11 uint16z
  (4, false, false, 0), // 12 uint32z
  (1, false, false, 0xff), // 13 byte
  (8, true, false, 0x7fffffffffffffff), // 14 sint64
  (8, false, false, -1), // 15 uint64
  (8, false, false, 0), // 16 uint64z
];

num? _read(ByteData d, int at, int base, Endian e) {
  if (base >= _bases.length) return null;
  final (size, signed, isFloat, invalid) = _bases[base];
  num v;
  switch (size) {
    case 1:
      v = signed ? d.getInt8(at) : d.getUint8(at);
      if ((v.toInt() & 0xff) == invalid) return null;
    case 2:
      v = signed ? d.getInt16(at, e) : d.getUint16(at, e);
      if ((v.toInt() & 0xffff) == invalid) return null;
    case 4:
      if (isFloat) {
        if (d.getUint32(at, e) == 0xffffffff) return null;
        return d.getFloat32(at, e);
      }
      v = signed ? d.getInt32(at, e) : d.getUint32(at, e);
      if ((v.toInt() & 0xffffffff) == invalid) return null;
    default:
      if (isFloat) return d.getFloat64(at, e);
      v = signed ? d.getInt64(at, e) : d.getUint64(at, e);
      if (v == invalid) return null;
  }
  return v;
}

/// Decodes every data message in a FIT file. Throws [FormatException] on a
/// file that is not FIT or is truncated mid-record; an undecodable file must
/// not be half-trusted.
List<FitMessage> parseFit(List<int> bytes) {
  final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (b.length < 12) throw const FormatException('FIT: too short');
  final headerSize = b[0];
  if ((headerSize != 12 && headerSize != 14) ||
      String.fromCharCodes(b.sublist(8, 12)) != '.FIT') {
    throw const FormatException('FIT: bad header');
  }
  final dataSize = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
  final end = headerSize + dataSize;
  if (end > b.length) throw const FormatException('FIT: truncated');
  final d = ByteData.sublistView(b);
  final defs = <int, _Def>{};
  final out = <FitMessage>[];
  int? lastTs; // FIT seconds
  var i = headerSize;
  while (i < end) {
    final h = b[i++];
    if (h & 0x80 != 0) {
      // Compressed-timestamp data record.
      final local = (h >> 5) & 0x3;
      final offset = h & 0x1f;
      if (lastTs != null) {
        lastTs = offset >= (lastTs & 0x1f)
            ? (lastTs & ~0x1f) + offset
            : (lastTs & ~0x1f) + offset + 0x20;
      }
      final def = defs[local];
      if (def == null) throw const FormatException('FIT: undefined local');
      final (msg, next, ts) = _data(d, i, def, lastTs);
      out.add(msg);
      i = next;
      if (ts != null) lastTs = ts;
      continue;
    }
    final local = h & 0x0f;
    if (h & 0x40 != 0) {
      if (i + 5 > end) throw const FormatException('FIT: truncated def');
      final endian = b[i + 1] == 1 ? Endian.big : Endian.little;
      final global = d.getUint16(i + 2, endian);
      final n = b[i + 4];
      i += 5;
      final fields = <_Field>[];
      for (var f = 0; f < n; f++) {
        fields.add(_Field(b[i], b[i + 1], b[i + 2] & 0x1f));
        i += 3;
      }
      var devBytes = 0;
      if (h & 0x20 != 0) {
        final nDev = b[i++];
        for (var f = 0; f < nDev; f++) {
          devBytes += b[i + 1];
          i += 3;
        }
      }
      defs[local] = _Def(global, endian, fields, devBytes);
    } else {
      final def = defs[local];
      if (def == null) throw const FormatException('FIT: undefined local');
      final (msg, next, ts) = _data(d, i, def, lastTs);
      out.add(msg);
      i = next;
      if (ts != null) lastTs = ts;
    }
    if (i > end) throw const FormatException('FIT: record overruns data');
  }
  return out;
}

(FitMessage, int, int?) _data(ByteData d, int at, _Def def, int? lastTs) {
  final fields = <int, Object>{};
  var i = at;
  for (final f in def.fields) {
    if (i + f.size > d.lengthInBytes) {
      throw const FormatException('FIT: truncated record');
    }
    if (f.base == 7) {
      final s = d.buffer.asUint8List(d.offsetInBytes + i, f.size);
      final z = s.indexOf(0);
      final str = String.fromCharCodes(z < 0 ? s : s.sublist(0, z));
      if (str.isNotEmpty) fields[f.num] = str;
    } else {
      final size = f.base < _bases.length ? _bases[f.base].$1 : 1;
      if (f.size == size) {
        final v = _read(d, i, f.base, def.endian);
        if (v != null) fields[f.num] = v;
      } else if (f.size % size == 0) {
        final list = <num?>[
          for (var k = 0; k < f.size; k += size)
            _read(d, i + k, f.base, def.endian),
        ];
        if (list.any((x) => x != null)) fields[f.num] = list;
      }
    }
    i += f.size;
  }
  i += def.devBytes;
  int? ts = (fields[253] as num?)?.toInt();
  // timestamp_16 (monitoring field 26): low 16 bits relative to the last
  // full timestamp.
  final ts16 = def.global == kFitMsgMonitoring ? fields[26] as num? : null;
  if (ts == null && ts16 != null && lastTs != null) {
    ts = lastTs + ((ts16.toInt() - (lastTs & 0xffff)) & 0xffff);
  }
  final unix = (ts ?? lastTs) == null ? null : (ts ?? lastTs)! + kFitEpochOffset;
  return (FitMessage(def.global, fields, unix), i, ts);
}

// ── typed views ─────────────────────────────────────────────────────────

/// Heart-rate samples from monitoring messages: (Unix seconds, bpm).
List<(int, int)> fitMonitoringHr(List<FitMessage> m) => [
      for (final x in m)
        if (x.global == kFitMsgMonitoring &&
            x.timestamp != null &&
            (x.num_(27) ?? 0) > 0)
          (x.timestamp!, x.num_(27)!.toInt()),
    ];

/// Steps per local day: monitoring `cycles` (field 3) is a running count per
/// activity type (field 5, or the low 5 bits of the packed field 24 when
/// field 5 is absent) that resets each day, so a day's steps are the
/// sum over walking (6) and running (1) of each type's largest count.
Map<DateTime, int> fitDailySteps(List<FitMessage> m) {
  final maxBy = <(DateTime, int), int>{};
  for (final x in m) {
    if (x.global != kFitMsgMonitoring || x.timestamp == null) continue;
    final packed = x.num_(24)?.toInt();
    final type = x.num_(5)?.toInt() ?? (packed == null ? null : packed & 0x1f);
    final cycles = x.num_(3)?.toInt();
    if (cycles == null || (type != 6 && type != 1)) continue;
    final t = DateTime.fromMillisecondsSinceEpoch(x.timestamp! * 1000);
    final key = (DateTime(t.year, t.month, t.day), type!);
    if (cycles > (maxBy[key] ?? -1)) maxBy[key] = cycles;
  }
  final out = <DateTime, int>{};
  maxBy.forEach((k, v) => out[k.$1] = (out[k.$1] ?? 0) + v);
  return out;
}

/// The watch's sleep stages as (startSec, endSec, stage) with stage one of
/// 'wake' | 'light' | 'deep' | 'rem'; each level runs until the next record
/// (the last for [lastLevelSeconds]). Unmeasurable or invalid periods are
/// dropped but still end the level before them.
List<(int, int, String)> fitSleepStages(List<FitMessage> m,
    {int lastLevelSeconds = 60}) {
  // A record with no valid level still ends the level before it.
  final levels = [
    for (final x in m)
      if (x.global == kFitMsgSleepLevel && x.timestamp != null)
        (x.timestamp!, x.num_(0)?.toInt() ?? -1),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(int, int, String)>[];
  for (var k = 0; k < levels.length; k++) {
    final (t, level) = levels[k];
    final end = k + 1 < levels.length ? levels[k + 1].$1 : t + lastLevelSeconds;
    final stage = switch (level) {
      1 => 'wake',
      2 => 'light',
      3 => 'deep',
      4 => 'rem',
      _ => null,
    };
    if (stage != null && end > t) out.add((t, end, stage));
  }
  return out;
}

/// Last night's average HRV in ms from an HRV status summary (field 1,
/// stored /128), with the summary's timestamp.
List<(int, double)> fitHrvLastNight(List<FitMessage> m) => [
      for (final x in m)
        if (x.global == kFitMsgHrvStatusSummary &&
            x.timestamp != null &&
            x.num_(1) != null)
          (x.timestamp!, x.num_(1)! / 128),
    ];

/// The watch's resting HR (field 1 current-day, else field 0).
List<(int, int)> fitRestingHr(List<FitMessage> m) => [
      for (final x in m)
        if (x.global == kFitMsgMonitoringHrData &&
            x.timestamp != null &&
            (x.num_(1) ?? x.num_(0)) != null)
          (x.timestamp!, (x.num_(1) ?? x.num_(0))!.toInt()),
    ];

/// SpO2 readings in percent (field 0), positive only.
List<(int, int)> fitSpo2(List<FitMessage> m) => [
      for (final x in m)
        if (x.global == kFitMsgSpo2Data &&
            x.timestamp != null &&
            (x.num_(0) ?? 0) > 0)
          (x.timestamp!, x.num_(0)!.toInt()),
    ];

/// Respiration rate in breaths/min (field 0, stored /100), positive only.
List<(int, double)> fitRespiration(List<FitMessage> m) => [
      for (final x in m)
        if (x.global == kFitMsgRespirationRate &&
            x.timestamp != null &&
            (x.num_(0) ?? 0) > 0)
          (x.timestamp!, x.num_(0)! / 100),
    ];

/// The watch's stress score 0-100 (field 0); negative values (no reading,
/// activity) dropped. Its own time is field 1 when present.
List<(int, int)> fitStress(List<FitMessage> m) => [
      for (final x in m)
        if (x.global == kFitMsgStressLevel && (x.num_(0) ?? -1) >= 0)
          if ((x.num_(1)?.toInt() ?? x.timestamp) case final t?)
            (x.num_(1) != null ? t + kFitEpochOffset : t, x.num_(0)!.toInt()),
    ];
