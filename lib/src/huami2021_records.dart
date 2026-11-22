// Huami2021/ZeppOS history record decoders (fetch endpoints, chars 0004
// control / 0005 data). Two timestamp styles: round-relative (roundStart +
// 60 s per record) and absolute (a `sec` field inside the record). `0xFF` is
// a sentinel meaning "allocated, never written" — dropped everywhere, never
// treated as a real zero/low reading.
//
// All multi-byte integers are little-endian.

import 'dart:typed_data';

int _u8(Uint8List b, int off) => b[off];
int _u16(Uint8List b, int off) => ByteData.sublistView(b).getUint16(off, Endian.little);
int _i16(Uint8List b, int off) => ByteData.sublistView(b).getInt16(off, Endian.little);
int _u32(Uint8List b, int off) => ByteData.sublistView(b).getUint32(off, Endian.little);

/// One decoded per-minute or per-event sample: a metric name, its Unix
/// milliseconds, and its value.
class Huami2021Sample {
  const Huami2021Sample(this.metric, this.ms, this.value);
  final String metric;
  final int ms;
  final double value;

  @override
  String toString() => 'Huami2021Sample($metric @ $ms = $value)';
}

/// Type `0x01`: `hr` and `steps`, one record per minute, round-relative.
/// 8 bytes per record normally; some rounds arrive 4-byte packed (steps u8 @
/// +2, hr u8 @ +3, no leading/trailing padding) instead.
///
/// [expectedRecordCount] (the fetch start reply's own announced count,
/// per `huami2021_fetch.dart`) resolves which form this round used WITHOUT
/// guessing: `data.length / expectedRecordCount` is exact either way. Pass
/// it whenever it's available — it is always available from a real fetch
/// round, so a caller with a live connection should never fall through to
/// the heuristic below.
///
/// The heuristic (`data.length % 8 == 0 ? 8 : 4`) is a fallback for when no
/// count is given (a unit test decoding a raw buffer with no round context,
/// say) and is WRONG whenever the true record count is even: an even
/// number of real 4-byte records is itself always a multiple of 8, so the
/// heuristic silently reads two real records as one 8-byte record,
/// collapsing N minutes into N/2 with corrupted values, not merely missing
/// ones. Never rely on it from a real fetch.
List<Huami2021Sample> parseHuami2021Activity(Uint8List data, int roundStartMs,
    {int? expectedRecordCount}) {
  final fromCount = (expectedRecordCount != null && expectedRecordCount > 0)
      ? data.length ~/ expectedRecordCount
      : 0;
  // A count so large relative to the byte length that it would divide down
  // to zero is not trustworthy either way — fall back to the heuristic
  // rather than risk a zero record size (which would never advance the
  // loop below).
  final recordSize =
      fromCount > 0 ? fromCount : (data.length % 8 == 0 ? 8 : 4);
  final out = <Huami2021Sample>[];
  for (var i = 0; i + recordSize <= data.length; i += recordSize) {
    final ms = roundStartMs + (i ~/ recordSize) * 60000;
    final steps = _u8(data, i + 2);
    final hr = _u8(data, i + 3);
    if (hr != 0xff && hr > 0) {
      out.add(Huami2021Sample('hr', ms, hr.toDouble()));
    }
    if (steps != 0xff && steps > 0) {
      out.add(Huami2021Sample('steps', ms, steps.toDouble()));
    }
  }
  return out;
}

/// Types `0x02` (`manual_hr`) and `0x12` (`stress_manual`): 6-byte absolute
/// records, `sec` u32 @ +0, value u8 @ +5. Kept when the value is neither
/// the sentinel nor zero.
List<Huami2021Sample> _parseAbsolute6(Uint8List data, String metric) {
  final out = <Huami2021Sample>[];
  for (var i = 0; i + 6 <= data.length; i += 6) {
    final sec = _u32(data, i);
    final value = _u8(data, i + 5);
    if (value != 0xff && value > 0) {
      out.add(Huami2021Sample(metric, sec * 1000, value.toDouble()));
    }
  }
  return out;
}

List<Huami2021Sample> parseHuami2021ManualHr(Uint8List data) =>
    _parseAbsolute6(data, 'manual_hr');
List<Huami2021Sample> parseHuami2021StressManual(Uint8List data) =>
    _parseAbsolute6(data, 'stress_manual');

/// Types `0x3A` (`resting_hr`) and `0x3D` (`max_hr`, 1 byte/record since it
/// is one value per round) and `0x49` (`hrv`): same 6-byte absolute shape as
/// above, reused for clarity at the call site.
List<Huami2021Sample> parseHuami2021RestingHr(Uint8List data) =>
    _parseAbsolute6(data, 'resting_hr');
List<Huami2021Sample> parseHuami2021MaxHr(Uint8List data) =>
    _parseAbsolute6(data, 'max_hr');
List<Huami2021Sample> parseHuami2021Hrv(Uint8List data) =>
    _parseAbsolute6(data, 'hrv');

/// Type `0x13`: `stress`, 1 byte/record, round-relative, value 0-100.
/// `0xFF` means no reading; anything else is kept, including 0.
List<Huami2021Sample> parseHuami2021Stress(Uint8List data, int roundStartMs) {
  final out = <Huami2021Sample>[];
  for (var i = 0; i < data.length; i++) {
    final v = data[i];
    if (v == 0xff) continue;
    out.add(Huami2021Sample('stress', roundStartMs + i * 60000, v.toDouble()));
  }
  return out;
}

/// Type `0x2E`: `temperature_c` (skin), 8 bytes/record, round-relative,
/// signed int16 at +2, hundredths of a degree.
///
/// Kept only for a plausible skin temperature, 20-45 C — the same bound
/// this codebase's other device-temperature adapter (Ultrahuman) already
/// uses, since this record carries no separate quality flag to combine with
/// the way that one does. An earlier version of this function kept every
/// raw value unfiltered on the theory that a higher analytics layer would
/// reject an outlier; for this device that layer doesn't exist between
/// decode and storage, so an implausible value (a zeroed or corrupted
/// record, say) would otherwise reach `decoded_onehz` as a measured
/// reading with nothing downstream to catch it.
List<Huami2021Sample> parseHuami2021Temperature(Uint8List data, int roundStartMs) {
  final out = <Huami2021Sample>[];
  for (var i = 0; i + 8 <= data.length; i += 8) {
    final raw = _i16(data, i + 2);
    final celsius = raw / 100.0;
    final ms = roundStartMs + (i ~/ 8) * 60000;
    if (celsius < 20 || celsius > 45) continue;
    out.add(Huami2021Sample('temperature_c', ms, celsius));
  }
  return out;
}

/// Type `0x38`: `respiratory_rate` (sleep), 8 bytes/record, absolute
/// `sec` u32 @ +0, breaths/min u8 @ +5. Dropped if sentinel or zero.
List<Huami2021Sample> parseHuami2021RespiratoryRate(Uint8List data) {
  final out = <Huami2021Sample>[];
  for (var i = 0; i + 8 <= data.length; i += 8) {
    final sec = _u32(data, i);
    final value = _u8(data, i + 5);
    if (value != 0xff && value > 0) {
      out.add(Huami2021Sample('respiratory_rate', sec * 1000, value.toDouble()));
    }
  }
  return out;
}

/// Type `0x25`: `spo2` (spot check), 65 bytes/record. The first byte of the
/// WHOLE payload is a version byte that must be `2`; each record inside is
/// then `sec u32 @ +0, value u8 @ +4` (`v >= 128 ? v - 128 : v`), one record
/// per `recordSize` chunk. Any other version yields no samples at all —
/// the layout for other versions isn't known, and guessing would be a
/// silent wrong answer.
///
/// The documented table has no stated keep-rule for this type, but `0xFF`
/// (and, after the `>=128` fold, `0x7F`) is this protocol's sentinel
/// everywhere else, and no real SpO2 reading is 0% or above 100% — kept
/// only for 1-100, same bound as [parseHuami2021Spo2Sleep]. An earlier
/// version of this function kept every byte verbatim, including 0 and the
/// folded sentinel (127); that was wrong and is what this bound fixes.
const int _spo2SpotRecordSize = 65;
List<Huami2021Sample> parseHuami2021Spo2Spot(Uint8List data) {
  if (data.isEmpty || data[0] != 2) return const [];
  final out = <Huami2021Sample>[];
  for (var i = 1; i + _spo2SpotRecordSize <= data.length; i += _spo2SpotRecordSize) {
    final sec = _u32(data, i);
    var value = _u8(data, i + 4);
    if (value >= 128) value -= 128;
    if (value < 1 || value > 100) continue;
    out.add(Huami2021Sample('spo2', sec * 1000, value.toDouble()));
  }
  return out;
}

/// Type `0x26`: `spo2_sleep`, 30 bytes/record after the version byte (must
/// be `2`), `sec u32 @ +0, percent u8 @ +4, durationSec u8 @ +5`. Kept for
/// 1-100%.
const int _spo2SleepRecordSize = 30;
List<Huami2021Sample> parseHuami2021Spo2Sleep(Uint8List data) {
  if (data.isEmpty || data[0] != 2) return const [];
  final out = <Huami2021Sample>[];
  for (var i = 1; i + _spo2SleepRecordSize <= data.length; i += _spo2SleepRecordSize) {
    final sec = _u32(data, i);
    final pct = _u8(data, i + 4);
    if (pct >= 1 && pct <= 100) {
      out.add(Huami2021Sample('spo2_sleep', sec * 1000, pct.toDouble()));
    }
  }
  return out;
}

/// Type `0x4E`: `hrv_sdnn`, 9 bytes/record, absolute `sec` u32 @ +0, a
/// signed tz-in-quarter-hours byte @ +4 (unused here; the caller resolves
/// local time from `sec` directly), SDNN as u32 @ +5 in hundredths of a
/// millisecond. Kept when the value is non-zero and not the 0xFFFFFFFF
/// sentinel.
///
/// NOTE: no known-value fixture covers this record; the layout is per the
/// documented spec only, unverified against a real capture.
List<Huami2021Sample> parseHuami2021HrvSdnn(Uint8List data) {
  final out = <Huami2021Sample>[];
  for (var i = 0; i + 9 <= data.length; i += 9) {
    final sec = _u32(data, i);
    final raw = _u32(data, i + 5);
    if (raw != 0 && raw != 0xFFFFFFFF) {
      out.add(Huami2021Sample('hrv_sdnn', sec * 1000, raw / 100.0));
    }
  }
  return out;
}

// --- Type 0x05: workout summaries (protobuf, no .proto shipped) ----------
//
// Each summary is a 2-byte prefix (not part of the message; `00 80` in
// every one of the 3 real records seen so far — too few samples to know if
// it ever varies, so it is treated as fixed rather than guessed at as a
// counter) followed by a protobuf message with fields (by number, as found
// by
// decoding real summaries byte-for-byte): 1 (string, a version tag, e.g.
// "2.1") · 2 (submessage: 1 varint start-time-seconds, 3 varint sport type)
// · 7 (submessage: 1 varint duration seconds) · 11 (submessage: 1 fixed32
// float, always 1.0, unused) · 16 (submessage: 1 varint calories) · 19
// (submessage: 1 varint avg HR, 2 varint max HR, 3 varint min HR). Field 7
// also appears once more at the top level as a fixed32 (always the 4 bytes
// 01 02 03 04) — a constant, not data; it is simply skipped.

class Huami2021Workout {
  const Huami2021Workout({
    required this.startMs,
    required this.durationSec,
    required this.sportType,
    required this.calories,
    required this.avgHr,
    required this.maxHr,
    required this.minHr,
  });

  final int startMs;
  final int durationSec;
  final int sportType;
  final int calories;
  final int avgHr;
  final int maxHr;
  final int minHr;
}

/// Thrown by the workout protobuf reader on truncated or malformed input —
/// caught by [parseHuami2021Workouts] itself, never left to surface as a
/// raw [RangeError] that could crash a caller that forgot to guard it.
class _HuamiProtobufTruncated implements Exception {
  const _HuamiProtobufTruncated();
}

/// Reads one protobuf varint starting at [off]; returns its value and the
/// offset just past it. Throws [_HuamiProtobufTruncated] rather than a raw
/// index-out-of-range error if the buffer ends mid-varint (a continuation
/// bit set on the last byte) — this protocol has no schema to validate
/// against, so a corrupted or unexpectedly-shaped workout record is a real
/// possibility, not a theoretical one, and must be recoverable rather than
/// a crash.
({int value, int next}) _varint(Uint8List data, int off) {
  var result = 0, shift = 0, i = off;
  while (true) {
    if (i >= data.length) throw const _HuamiProtobufTruncated();
    final b = data[i];
    i++;
    result |= (b & 0x7f) << shift;
    if (b & 0x80 == 0) break;
    shift += 7;
  }
  return (value: result, next: i);
}

/// Walks a flat protobuf message, calling [onField] with (fieldNumber,
/// wireType, valueBytesOrInt) for each field in wire order. Stops at [end].
/// Unknown wire type 3/4 (start/end group) ends the walk early rather than
/// guessing at its length — callers get whatever fields were read so far.
void _walkProtobuf(Uint8List data, int start, int end,
    void Function(int fieldNo, int wireType, int off, int len) onField) {
  var i = start;
  while (i < end) {
    final tagRead = _varint(data, i);
    final tag = tagRead.value;
    i = tagRead.next;
    final fieldNo = tag >> 3;
    final wireType = tag & 7;
    switch (wireType) {
      case 0: // varint
        final v = _varint(data, i);
        onField(fieldNo, wireType, i, v.next - i);
        i = v.next;
      case 1: // fixed64
        onField(fieldNo, wireType, i, 8);
        i += 8;
      case 2: // length-delimited
        final lenRead = _varint(data, i);
        final contentStart = lenRead.next;
        onField(fieldNo, wireType, contentStart, lenRead.value);
        i = contentStart + lenRead.value;
      case 5: // fixed32
        onField(fieldNo, wireType, i, 4);
        i += 4;
      default:
        return; // group start/end: not used by this protocol, stop here
    }
  }
}

int _varintFieldValue(Uint8List data, int off, int len) => _varint(data, off).value;

/// Parses every workout summary in [data]: a 2-byte prefix, then one
/// protobuf message, repeated back to back. Messages aren't individually
/// length-prefixed in the stream, so each one is read as a flat top-level
/// field sequence and stops as soon as field 19 (avg/max/min HR) has been
/// read — every real summary seen so far ends there, with the next
/// record's own 2-byte prefix immediately following.
List<Huami2021Workout> parseHuami2021Workouts(Uint8List data) {
  final out = <Huami2021Workout>[];
  var cursor = 0;
  while (cursor < data.length) {
    cursor += 2; // the leading 2-byte prefix
    if (cursor >= data.length) break;

    int? startSec, durationSec, sportType, calories, avgHr, maxHr, minHr;
    var i = cursor;
    try {
      var sawField19 = false;
      while (i < data.length && !sawField19) {
        final tagRead = _varint(data, i);
        final fieldNo = tagRead.value >> 3;
        final wireType = tagRead.value & 7;
        i = tagRead.next;
        switch (wireType) {
          case 0:
            final v = _varint(data, i);
            i = v.next;
          case 1:
            i += 8;
          case 2:
            final lenRead = _varint(data, i);
            final contentStart = lenRead.next;
            final contentEnd = contentStart + lenRead.value;
            if (contentEnd > data.length) throw const _HuamiProtobufTruncated();
            if (fieldNo == 2) {
              _walkProtobuf(data, contentStart, contentEnd, (f, w, o, l) {
                if (f == 1 && w == 0) startSec = _varintFieldValue(data, o, l);
                if (f == 3 && w == 0) sportType = _varintFieldValue(data, o, l);
              });
            } else if (fieldNo == 7) {
              _walkProtobuf(data, contentStart, contentEnd, (f, w, o, l) {
                if (f == 1 && w == 0) durationSec = _varintFieldValue(data, o, l);
              });
            } else if (fieldNo == 16) {
              _walkProtobuf(data, contentStart, contentEnd, (f, w, o, l) {
                if (f == 1 && w == 0) calories = _varintFieldValue(data, o, l);
              });
            } else if (fieldNo == 19) {
              _walkProtobuf(data, contentStart, contentEnd, (f, w, o, l) {
                if (f == 1 && w == 0) avgHr = _varintFieldValue(data, o, l);
                if (f == 2 && w == 0) maxHr = _varintFieldValue(data, o, l);
                if (f == 3 && w == 0) minHr = _varintFieldValue(data, o, l);
              });
              sawField19 = true;
            }
            i = contentEnd;
          case 5:
            if (i + 4 > data.length) throw const _HuamiProtobufTruncated();
            i += 4;
          default:
            i = data.length; // unknown wire type: stop, don't guess
        }
      }
    } on _HuamiProtobufTruncated {
      // This record (and anything after it in this buffer) can't be
      // trusted — there is no length prefix to resync on, so guessing at
      // where the next record starts would risk silently misparsing it.
      // Every workout already decoded before this one stays valid; return
      // them rather than crash the caller, which would otherwise lose
      // everything else the session fetched alongside workouts.
      return out;
    }

    if (startSec != null && startSec! >= 1000000000) {
      out.add(Huami2021Workout(
        startMs: startSec! * 1000,
        durationSec: durationSec ?? 0,
        sportType: sportType ?? 0,
        calories: calories ?? 0,
        avgHr: avgHr ?? 0,
        maxHr: maxHr ?? 0,
        minHr: minHr ?? 0,
      ));
    }
    cursor = i;
  }
  return out;
}

/// Type `0x0D`: `pai_daily`/`pai_total` (the strap's own Personal Activity
/// Intelligence score). A version byte, then one record per round:
/// `sec u32 @ +1, daily f32 @ +55, 7-day total f32 @ +59`; record size is
/// 69 bytes for version < 2, 97 for 2-3, 99 for 4, 102 for version >= 5.
/// Kept only when the version matches a known size, `sec` is plausible,
/// and both values are finite and within 0-1000.
///
/// NOTE: no known-value fixture covers this record; the layout is per the
/// documented spec only, unverified against a real capture.
class Huami2021Pai {
  const Huami2021Pai(this.ms, this.daily, this.total);
  final int ms;
  final double daily;
  final double total;
}

int? _paiRecordSize(int version) => switch (version) {
      < 2 => 69,
      2 || 3 => 97,
      4 => 99,
      >= 5 => 102,
      _ => null,
    };

List<Huami2021Pai> parseHuami2021Pai(Uint8List data) {
  if (data.isEmpty) return const [];
  final version = data[0];
  final recordSize = _paiRecordSize(version);
  if (recordSize == null) return const [];
  final out = <Huami2021Pai>[];
  for (var i = 1; i + recordSize <= data.length; i += recordSize) {
    final sec = _u32(data, i);
    if (sec < 1600000000 || sec > 2000000000) continue;
    final daily = ByteData.sublistView(data).getFloat32(i + 54, Endian.little);
    final total = ByteData.sublistView(data).getFloat32(i + 58, Endian.little);
    if (!daily.isFinite || !total.isFinite) continue;
    if (daily < 0 || daily > 1000 || total < 0 || total > 1000) continue;
    out.add(Huami2021Pai(sec * 1000, daily, total));
  }
  return out;
}

/// Type `0x4A`: a nightly sleep-apnea summary, 2896 bytes. `belongTime` (the
/// local midnight starting the wake day) u32 @ +0, valid-time u32 @ +4,
/// `odiRefined` u32 @ +8, score u8 @ +12, 240 undecoded `{sec, value,
/// duration}` i32 triples from +16 on (not read here — their meaning past
/// the headline fields is not established).
///
/// NOTE: no known-value fixture covers this record; the units of
/// `odiRefined` and the score are UNVERIFIED per the spec itself. Valid
/// time is kept whenever `belongTime` is plausible; the rest of the summary
/// is withheld unless its own value is greater than zero, since an
/// unmeasured night is not the same as a zero.
class Huami2021OdiSummary {
  const Huami2021OdiSummary({
    required this.belongTimeMs,
    required this.validTimeSec,
    this.odiRefined,
    this.score,
  });
  final int belongTimeMs;
  final int validTimeSec;
  final int? odiRefined;
  final int? score;
}

const int _odiSummaryRecordSize = 2896;

List<Huami2021OdiSummary> parseHuami2021OdiSummary(Uint8List data) {
  final out = <Huami2021OdiSummary>[];
  for (var i = 0; i + _odiSummaryRecordSize <= data.length; i += _odiSummaryRecordSize) {
    final belongTime = _u32(data, i);
    if (belongTime < 1600000000 || belongTime > 2000000000) continue;
    final validTime = _u32(data, i + 4);
    final odiRefined = _u32(data, i + 8);
    final score = _u8(data, i + 12);
    out.add(Huami2021OdiSummary(
      belongTimeMs: belongTime * 1000,
      validTimeSec: validTime,
      odiRefined: odiRefined > 0 ? odiRefined : null,
      score: score != 0xff ? score : null,
    ));
  }
  return out;
}

// --- Type 0x48: sleep sessions (594-byte slots) --------------------------

/// Stage type constants (the rest pass through as opaque small ints).
const int kHuami2021StageAwake = 7;
const int kHuami2021StageLight = 4;
const int kHuami2021StageDeep = 5;
const int kHuami2021StageRem = 8;
const int _gapMarkerType = 0x80;

const int _sleepRecordSize = 594;

/// One contiguous stage within a session: a wake, light, deep or REM span.
class Huami2021Stage {
  const Huami2021Stage(this.startMs, this.endMs, this.type);
  final int startMs;
  final int endMs;
  final int type;

  @override
  String toString() => 'Huami2021Stage($startMs..$endMs type=$type)';
}

/// One sleep session: a full night, or a nap found within a night's own
/// slot. A nap's `avgHr`/`score` are always 0 (the device doesn't score
/// naps); its REM/light/deep/wake minutes are summed from its own [stages],
/// not read from the night's totals.
class Huami2021SleepSession {
  const Huami2021SleepSession({
    required this.sessionStartMs,
    required this.isNap,
    required this.avgHr,
    required this.score,
    required this.sleepStartMin,
    required this.sleepEndMin,
    required this.remMin,
    required this.lightMin,
    required this.deepMin,
    required this.wakeMin,
    required this.stages,
  });

  final int sessionStartMs;
  final bool isNap;
  final int avgHr;
  final int score;
  final int sleepStartMin;
  final int sleepEndMin;
  final int remMin;
  final int lightMin;
  final int deepMin;
  final int wakeMin;
  final List<Huami2021Stage> stages;
}

/// Reads one {start u16, end u16, type u8} stage slot at [off], or null for
/// a `{0,0}` entry (a terminator for the night timeline, a gap for the
/// shared nap timeline — the caller decides which).
({int start, int end, int type})? _readStageSlot(Uint8List data, int off) {
  final start = _u16(data, off);
  final end = _u16(data, off + 2);
  if (start == 0 && end == 0) return null;
  return (start: start, end: end, type: _u8(data, off + 4));
}

/// Parses every valid 594-byte sleep slot in [data] (an invalid slot is
/// skipped, not fatal — a later slot may still be a real session). Each
/// valid slot yields its main night session, plus one [Huami2021SleepSession]
/// per nap descriptor that actually has stages.
List<Huami2021SleepSession> parseHuami2021Sleep(Uint8List data) {
  final out = <Huami2021SleepSession>[];
  for (var base = 0; base + _sleepRecordSize <= data.length; base += _sleepRecordSize) {
    final sessionSec = _u32(data, base + 0x000);
    final midnightSec = _u32(data, base + 0x004);
    final marker0 = _u8(data, base + 0x008);
    final marker1 = _u8(data, base + 0x009);
    const minSec = 1600000000, maxSec = 2000000000;
    if (sessionSec < minSec ||
        sessionSec > maxSec ||
        midnightSec < minSec ||
        midnightSec > maxSec ||
        marker0 != 1 ||
        marker1 != 1) {
      continue; // skip this slot, a later one may still be valid
    }
    // Stage minutes are offsets from (midnight - 24h) on the strap's own
    // wall clock; this layer passes that arithmetic through verbatim and
    // leaves timezone resolution to the caller.
    final reference = midnightSec - 86400;
    int msAt(int minutes) => (reference + minutes * 60) * 1000;

    final sleepStartMin = _u16(data, base + 0x00a);
    final sleepEndMin = _u16(data, base + 0x00c);
    final avgHr = _u8(data, base + 0x015);
    final score = _u8(data, base + 0x016);
    final remMin = _u16(data, base + 0x24a);
    final lightMin = _u16(data, base + 0x24c);
    final deepMin = _u16(data, base + 0x24e);
    final wakeMin = _u16(data, base + 0x250);

    final nightStages = <Huami2021Stage>[];
    final nightStagesStart = base + 0x056;
    final nightStagesEnd = base + 0x155;
    for (var off = nightStagesStart; off + 5 <= nightStagesEnd; off += 5) {
      final slot = _readStageSlot(data, off);
      if (slot == null) break; // {0,0} terminates the night timeline
      if (slot.type == _gapMarkerType) continue;
      nightStages.add(Huami2021Stage(
          msAt(slot.start), msAt(slot.end), slot.type));
    }

    out.add(Huami2021SleepSession(
      sessionStartMs: sessionSec * 1000,
      isNap: false,
      avgHr: avgHr,
      score: score,
      sleepStartMin: sleepStartMin,
      sleepEndMin: sleepEndMin,
      remMin: remMin,
      lightMin: lightMin,
      deepMin: deepMin,
      wakeMin: wakeMin,
      stages: nightStages,
    ));

    // Nap descriptors share one stage timeline (0x155..0x24a) across every
    // nap in this slot; a nap's own stages are those whose start falls
    // within its descriptor's [start, end].
    final napDescStart = base + 0x018;
    final napDescEnd = base + 0x054;
    final napStagesStart = base + 0x155;
    final napStagesEnd = base + 0x24a;
    for (var dOff = napDescStart; dOff + 6 <= napDescEnd; dOff += 6) {
      final napStart = _u16(data, dOff);
      final napEnd = _u16(data, dOff + 2);
      final napDur = _u16(data, dOff + 4);
      if (napStart == 0 && napDur == 0) break;
      if (!(napDur > 0 && napEnd > napStart)) continue;

      final napStages = <Huami2021Stage>[];
      var rem = 0, light = 0, deep = 0, wake = 0;
      for (var off = napStagesStart; off + 5 <= napStagesEnd; off += 5) {
        final slot = _readStageSlot(data, off);
        if (slot == null) continue; // a gap in the shared timeline, not this nap's end
        if (slot.type == _gapMarkerType) continue;
        if (slot.start < napStart || slot.start > napEnd) continue;
        napStages.add(Huami2021Stage(msAt(slot.start), msAt(slot.end), slot.type));
        final minutes = slot.end - slot.start;
        switch (slot.type) {
          case kHuami2021StageRem:
            rem += minutes;
          case kHuami2021StageLight:
            light += minutes;
          case kHuami2021StageDeep:
            deep += minutes;
          case kHuami2021StageAwake:
            wake += minutes;
        }
      }
      if (napStages.isEmpty) continue; // a descriptor with no stages isn't a session

      out.add(Huami2021SleepSession(
        sessionStartMs: msAt(napStart),
        isNap: true,
        avgHr: 0,
        score: 0,
        sleepStartMin: napStart,
        sleepEndMin: napEnd,
        remMin: rem,
        lightMin: light,
        deepMin: deep,
        wakeMin: wake,
        stages: napStages,
      ));
    }
  }
  return out;
}
