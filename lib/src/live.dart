// live.dart — 1:1 Dart port of ts/live.ts.
// Live + IMU frame decoders (R10/0x28/0x33/R24 dispatch, IMU accel magnitudes,
// realtime RR, R10 motion activity + autocorrelation steps).
// PURE Dart — dart:typed_data + dart:math only.

import 'dart:math' as math;
import 'dart:typed_data';

import 'constants.dart';
import 'gen5_records.dart';
import 'records.dart';

/// A decoded HR/activity sample.
class DecodedSample {
  final int ts; // unix seconds
  final int hr; // bpm (0 = off-wrist / no reading)

  /// Motion magnitude (stddev of |accel(g)|) over this record's IMU window.
  ///
  /// NULL means "this record carried no usable IMU data" — an R10 frame that
  /// was truncated before the accel arrays. That is NOT the same claim as
  /// `0.0`, which means "the IMU was read and the wrist was still". The old
  /// code returned 0.0 for both, so a truncated frame was indistinguishable
  /// from a genuine zero-motion reading downstream.
  final double? activity;

  /// Steps detected in this record's IMU window (R10 only). Null when the IMU
  /// window was unreadable (see [activity]); `0` means "read, no gait found".
  final int? stepsInc;
  final bool wristOn; // worn proxy (hr>0)
  final int recType; // 7 | 9 | 10 | 12 | 18 | 24 | 25 | 28

  DecodedSample({
    required this.ts,
    required this.hr,
    required this.activity,
    required this.stepsInc,
    required this.wristOn,
    required this.recType,
  });

  Map<String, dynamic> toMap() => {
    'ts': ts,
    'hr': hr,
    'activity': activity,
    'steps_inc': stepsInc,
    'wrist_on': wristOn,
    'rec_type': recType,
  };
}

/// One IMU frame's accel as ordered magnitude samples (g) + its time + sub-order.
class ImuFrame {
  final int ts;
  final int idx;
  final List<double> mags;
  final List<double>? xs;
  final List<double>? ys;
  final List<double>? zs;
  ImuFrame(this.ts, this.idx, this.mags, [this.xs, this.ys, this.zs]);

  Map<String, dynamic> toMap() => {'ts': ts, 'idx': idx, 'mags': mags, 'xs': xs, 'ys': ys, 'zs': zs};
}

/// Nibble value for an ASCII hex code unit, or -1 if it is not a hex digit.
int _nibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
  if (c >= 0x61 && c <= 0x66) return c - 0x57; // a-f
  if (c >= 0x41 && c <= 0x46) return c - 0x37; // A-F
  return -1;
}

Uint8List hexToBytes(String hex) {
  final trimmed = hex.trim();
  // An odd-length string is a truncated record, not a shorter one. Flooring to
  // whole bytes would drop the trailing nibble and hand the caller a payload
  // that decodes cleanly at the wrong length.
  if (trimmed.length.isOdd) {
    throw FormatException('odd-length hex', trimmed, trimmed.length);
  }
  final out = Uint8List(trimmed.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    final hi = _nibble(trimmed.codeUnitAt(i * 2));
    final lo = _nibble(trimmed.codeUnitAt(i * 2 + 1));
    // Keep throwing on non-hex input. Callers rely on it: live.dart,
    // substrate.dart, db.dart and ble_engine.dart all treat a FormatException
    // as "this string is not a record", and a lookup that returned 0 instead
    // would hand them fabricated bytes.
    if (hi < 0 || lo < 0) {
      throw FormatException('not a hex byte', trimmed, i * 2);
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

// JS Math.round: round half toward +Infinity.
double _jsRound(double v) => (v + 0.5).floorToDouble();

/// frameAccel — decode one IMU frame's accelerometer into ordered |accel|(g)
/// samples. Handles 0x33 live IMU stream and R10. Returns null if not an
/// accel-bearing frame.
ImuFrame? frameAccel(String hex) {
  Uint8List b;
  try {
    b = hexToBytes(hex);
  } catch (_) {
    return null;
  }
  if (b.length < 32) return null;
  final view = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  final pkt = b[0], rec = b[1];
  // 0x33 IMU stream: 10 accel samples (X,Y,Z) from offset 24.
  if (pkt == 0x33 && b.length >= 84) {
    final ts = view.getUint32(4, Endian.little);
    final idx = view.getUint16(14, Endian.little);
    final mags = <double>[];
    final xs = <double>[];
    final ys = <double>[];
    final zs = <double>[];
    for (int i = 0; i < 10; i++) {
      final x = view.getInt16(24 + 2 * i, Endian.little);
      final y = view.getInt16(24 + 2 * (10 + i), Endian.little);
      final z = view.getInt16(24 + 2 * (20 + i), Endian.little);
      xs.add(x.toDouble());
      ys.add(y.toDouble());
      zs.add(z.toDouble());
      mags.add(math.sqrt(x * x + y * y + z * z) / 4096);
    }
    return ts > 0 ? ImuFrame(ts, idx, mags, xs, ys, zs) : null;
  }
  // R10: rec 0x0A, ts@7, accel X@85/Y@285/Z@485 (100 int16 each).
  if (rec == 0x0a && b.length >= 685) {
    final ts = view.getUint32(7, Endian.little);
    final mags = <double>[];
    final xs = <double>[];
    final ys = <double>[];
    final zs = <double>[];
    for (int i = 0; i < 100; i++) {
      final x = view.getInt16(85 + 2 * i, Endian.little);
      final y = view.getInt16(285 + 2 * i, Endian.little);
      final z = view.getInt16(485 + 2 * i, Endian.little);
      xs.add(x.toDouble());
      ys.add(y.toDouble());
      zs.add(z.toDouble());
      mags.add(math.sqrt(x * x + y * y + z * z) / 4096);
    }
    return ts > 0 ? ImuFrame(ts, 0, mags, xs, ys, zs) : null;
  }
  return null;
}

/// frameAccelGen5Live — the gen5 live IMU stream (packet type 0x2B carrying a
/// record-21 buffer), decoded into the same [ImuFrame] shape [frameAccel]
/// returns. Null if [hex] is not that frame.
///
/// It is the same buffer the historical path decodes, so both share
/// [parseGen5ImuBuffer] rather than repeating the offsets. Axis samples are
/// raw int16 and `mags` is in g, matching [frameAccel]'s convention.
///
/// Unlike [frameAccel] this does NOT drop the frame when the timestamp is
/// missing: the accelerometer samples are valid whether or not the strap's
/// clock has been set, and callers that need a wall time supply their own.
ImuFrame? frameAccelGen5Live(String hex) {
  Uint8List b;
  try {
    b = hexToBytes(hex);
  } catch (_) {
    return null;
  }
  if (b.isEmpty || b[0] != PacketType.realtimeRawData) return null;
  final buf = parseGen5ImuBuffer(b);
  if (buf == null) return null;

  final xs = <double>[];
  final ys = <double>[];
  final zs = <double>[];
  final mags = <double>[];
  for (int i = 0; i < buf.accelXg.length; i++) {
    final xg = buf.accelXg[i];
    final yg = buf.accelYg[i];
    final zg = buf.accelZg[i];
    // Axes back to raw LSB so they read the same as frameAccel's; the
    // magnitude stays in g.
    xs.add(xg / kGen5AccelScaleG);
    ys.add(yg / kGen5AccelScaleG);
    zs.add(zg / kGen5AccelScaleG);
    mags.add(math.sqrt(xg * xg + yg * yg + zg * zg));
  }
  return ImuFrame(buf.unix, 0, mags, xs, ys, zs);
}

/// Try the gen5 live IMU layout first, then gen4's ([frameAccel]). Safe to call
/// for either generation — the two gates cannot both match.
ImuFrame? frameAccelForBand(String hex) =>
    frameAccelGen5Live(hex) ?? frameAccel(hex);

/// Beat-to-beat (R-R) intervals (ms) from the live records that carry them.
///   • 0x28 REALTIME_DATA (compact HR): rr_count u8 @ [9],  rr i16 LE @ [10 + 2i]
///   • R10  (rec_type 10):              rr_count u8 @ [18], rr i16 LE @ [19 + 2i]
/// Returns {ts, rr_ms} or null.
///
/// The declared count is untrusted on both forms and is capped at the number
/// of R-R slots that form actually has (4 for 0x28, [kMaxRrPerRecord] for R10).
RealtimeRrResult? realtimeRr(String hex) {
  Uint8List b;
  try {
    b = hexToBytes(hex);
  } catch (_) {
    return null;
  }
  if (b.length < 12) return null;
  final view = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  final pkt = b[0], rec = b[1];
  int tsOff, cntOff, maxRr;
  if (pkt == 0x28) {
    tsOff = 2;
    cntOff = 9;
    // A 0x28 packet is 20 bytes and has exactly FOUR R-R slots — [10] [12]
    // [14] [16] — bounded by the wearing byte at [18]. A declared count of
    // 5..8 used to be accepted, which read [18] (and the byte after it) as
    // heartbeats, with the 200–2500 ms range check as the only thing standing
    // between the wearing flag and live HRV/breathing compute. Four slots
    // exist, so four is the ceiling.
    maxRr = 4;
  } else if (rec == 10) {
    tsOff = 7;
    cntOff = 18;
    // R10 declares its count at [18] and carries the values from [19], inside
    // a 1920-byte record — there is genuine room for these, so the historical
    // ceiling applies unchanged.
    maxRr = kMaxRrPerRecord;
  } else {
    return null;
  }
  if (cntOff + 1 >= b.length) return null;
  final ts = view.getUint32(tsOff, Endian.little);
  if (ts <= 0) return null;
  final n = b[cntOff];
  if (n == 0 || n > maxRr) {
    return null; // more beats than this form has slots = wrong offset
  }
  final rrMs = <int>[];
  final first = cntOff + 1;
  for (int i = 0; i < n && first + 2 * i + 2 <= b.length; i++) {
    final v = view.getInt16(first + 2 * i, Endian.little);
    // Same physiological range records.dart and control.dart gate on — a
    // misaligned or corrupted slot should not reach live HRV/breathing
    // compute as a beat just because this decoder forgot to check it too.
    if (v >= kMinRrMs && v <= kMaxRrMs) rrMs.add(v);
  }
  return rrMs.isNotEmpty ? RealtimeRrResult(ts, rrMs) : null;
}

/// Result of [realtimeRr].
class RealtimeRrResult {
  final int ts;
  final List<int> rrMs;
  RealtimeRrResult(this.ts, this.rrMs);

  Map<String, dynamic> toMap() => {'ts': ts, 'rr_ms': rrMs};
}

class _Motion {
  final double activity;
  final int steps;
  _Motion(this.activity, this.steps);
}

// Decode the R10 IMU arrays into (activity, steps) over the 100-sample window.
// Returns NULL when the frame is too short to contain the accel arrays at all
// — "we could not measure motion", which the caller surfaces as a null
// activity/steps rather than a fabricated 0.0/0 that reads like a real
// zero-motion sample. A non-null result with steps==0 IS a measurement: the
// window was read and no gait rhythm was found.
_Motion? _r10Motion(ByteData view, int len) {
  if (len < 685) return null;
  const acc = 1 / 4096;
  List<int> arr(int off) {
    final out = <int>[];
    for (int i = 0; i < 100; i++) {
      final o = off + 2 * i;
      if (o + 2 <= len) out.add(view.getInt16(o, Endian.little));
    }
    return out;
  }

  final ax = arr(85), ay = arr(285), az = arr(485);
  final n = math.min(ax.length, math.min(ay.length, az.length));
  if (n == 0) return null; // nothing measured — same absence as a short frame.
  final mags = <double>[];
  for (int i = 0; i < n; i++) {
    final x = ax[i] * acc, y = ay[i] * acc, z = az[i] * acc;
    mags.add(math.sqrt(x * x + y * y + z * z));
  }
  double sum = 0;
  for (final v in mags) {
    sum += v;
  }
  final mean = sum / n;
  double varSum = 0;
  for (final v in mags) {
    varSum += (v - mean) * (v - mean);
  }
  final variance = varSum / n;
  final std = math.sqrt(variance);
  final activity = _jsRound(std * 1000) / 1000;

  const activityFloor = 0.05;
  if (std < activityFloor || n < 24) return _Motion(activity, 0);

  // ── What this step search can and cannot find ────────────────────────────
  // gen4 R10 is 100 Hz: 100 accel samples per record, one record per second
  // (verified on real captures — consecutive R10 timestamps step by exactly
  // 1 s while each record carries 100 samples per axis). At that rate:
  //
  //   • the detrend window below is ±9 samples = 190 ms. Subtracting a 19-tap
  //     moving average high-passes at about 0.443·fs/N ≈ 2.3 Hz, which sits
  //     inside the 1.5–3 Hz gait fundamental and attenuates it before the
  //     search ever runs;
  //   • the autocorrelation lag window (7..40 samples = 70–400 ms) can only
  //     resolve cadences of 150–857 steps/min. Ordinary walking is 100–130
  //     steps/min, which lives at lags 46–60 and is therefore UNREACHABLE.
  //
  // So on every real R10 record available to us this returns 0 steps. Read
  // that as "this search found no cadence it can see", NOT as a measurement
  // that the wearer was still.
  //
  // The constants are deliberately NOT retuned. Widening the window does not
  // make any real record we hold produce a step either, so replacement
  // constants would be exactly as unvalidated as these — they would only hide
  // the gap behind numbers that look deliberate. Retune against a capture with
  // an independently known step count, or not at all.
  const w = 9;
  final x = List<double>.filled(n, 0);
  for (int i = 0; i < n; i++) {
    double s = 0;
    int c = 0;
    for (int j = math.max(0, i - w); j <= math.min(n - 1, i + w); j++) {
      s += mags[j];
      c++;
    }
    x[i] = mags[i] - s / c;
  }
  double x0sum = 0;
  for (final v in x) {
    x0sum += v;
  }
  final x0 = x0sum / n;
  double denom = 0;
  for (int i = 0; i < n; i++) {
    denom += (x[i] - x0) * (x[i] - x0);
  }
  if (denom <= 1e-9) return _Motion(activity, 0);

  const minLag = 7, maxLag = 40;
  int bestLag = 0;
  double bestR = 0;
  for (int lag = minLag; lag <= math.min(maxLag, n - 1); lag++) {
    double num = 0;
    for (int i = 0; i < n - lag; i++) {
      num += (x[i] - x0) * (x[i + lag] - x0);
    }
    final r = num / denom;
    if (r > bestR) {
      bestR = r;
      bestLag = lag;
    }
  }

  const rhythmThresh = 0.45;
  if (bestLag == 0 || bestR < rhythmThresh) return _Motion(activity, 0);
  final steps = _jsRound(n / bestLag).toInt();
  return _Motion(activity, steps);
}

/// Decode one hex record into a [DecodedSample], or null if it carries no
/// surfaceable sample (0x33 IMU stream, malformed, or unknown type).
DecodedSample? decodeRecord(String hex) {
  Uint8List b;
  try {
    b = hexToBytes(hex);
  } catch (_) {
    return null;
  }
  if (b.length < 4) return null;
  final view = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  final pktType = b[0];
  final recType = b[1];

  // 0x28 — live compact HR: ts@2 (u32 LE), hr@8 (u8). NO RR-intervals.
  if (pktType == 0x28) {
    if (b.length < 9) return null;
    final ts = view.getUint32(2, Endian.little);
    final hr = b[8];
    return DecodedSample(
      ts: ts,
      hr: hr,
      // A 0x28 packet is 20 bytes of timing + HR + R-R + a wearing byte. It
      // carries NO IMU at all, so there is no motion window to measure —
      // exactly the absence [DecodedSample.activity] documents, not a measured
      // 0.0/0. Reporting zero here fabricated "the wrist was perfectly still"
      // out of bytes that never described motion, which is the same bug this
      // decoder family was fixed to stop making on the R10 and historical
      // paths.
      activity: null,
      stepsInc: null,
      wristOn: hr > 0,
      recType: 28,
    );
  }

  // 0x33 — live IMU stream: raw-only (no sample emitted).
  if (pktType == 0x33) return null;

  if (b.length < 18) return null;

  // WHOOP 4 historical telemetry — EVERY layout version parseR24 has a field
  // map for, not just v24/v25. v12 in particular is real, shipping firmware
  // (Record.r12); routing it to null here cost the caller the record's own
  // timestamp, so a multi-day backfill collapsed onto the capture time.
  // parseR24 owns the per-version HR offset and the plausibility gate, so the
  // versions it cannot decode honestly still come back null.
  if (kKnownRecordVersions.contains(recType)) {
    final d = parseR24(b);
    if (d == null) return null;
    return DecodedSample(
      ts: d.tsEpoch,
      hr: d.hr,
      // On `wristOn` below: skinContact is contact QUALITY, not wear. 28 real
      // v24 records in the parity fixture read hr 87-97 (clearly worn) with
      // skinContact <= 50, so a contact threshold would call them off-wrist.
      // `hr > 0` is kept for that reason.
      //
      // But the parity oracle cannot EVIDENCE it. `decode_parity_cases.json`'s
      // `wrist_on` column was GENERATED by the same rule, verbatim:
      //
      //     wrist_on: d.hr > 0
      //
      // so the oracle agreeing is the expression read back, not confirmation.
      // That line lived in `ts/live.ts`, which this commit removes; it is
      // recorded here rather than by path so the provenance survives the
      // deletion, and remains recoverable at protocol main 7edcb3e:
      //
      //     git show 7edcb3e:ts/live.ts | sed -n '229p'
      //
      // Confirming `hr > 0` needs captures with independently known wear
      // state, not the fixture.
      // This record family carries no IMU stepping window at all — that is
      // "no usable IMU data", the same absence [DecodedSample.activity]'s
      // doc comment describes for a truncated R10, not a measured 0.0/0.
      // Fabricating zero here is the exact bug this decoder family was just
      // fixed to stop making for R10.
      activity: null,
      stepsInc: null,
      wristOn: d.hr > 0,
      recType: recType,
    );
  }

  // R10 / 0x2B — ts@7, hr@17, IMU arrays → activity.
  if (recType == 10) {
    final ts = view.getUint32(7, Endian.little);
    final hr = b[17];
    // Null motion = the frame carried no readable IMU window; propagate that
    // absence instead of reporting a measured zero.
    final m = _r10Motion(view, b.length);
    return DecodedSample(
      ts: ts,
      hr: hr,
      activity: m?.activity,
      stepsInc: m?.steps,
      wristOn: hr > 0,
      recType: 10,
    );
  }

  return null;
}

/// Full IMU payload of one live R10 record: 100 samples/axis of accelerometer
/// (g) and gyroscope (deg/s), plus the record timestamp.
class R10Imu {
  final int ts; // unix seconds (device clock; may be unset on a fresh band)
  final List<double> accelX; // g
  final List<double> accelY;
  final List<double> accelZ;
  final List<double> gyroX; // deg/s
  final List<double> gyroY;
  final List<double> gyroZ;

  R10Imu({
    required this.ts,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
  });
}

// Gyro full-scale ±2000 dps over signed int16 → 2000/32768 deg/s per LSB.
const double _gyroScale = 0.06103515625;
const double _accelScale = 1 / 4096;

/// Decode the full accel + gyro IMU arrays from a live R10 record
/// (inner packet `0x2B`, record type `0x0A`). Layout (our base, verified on a
/// real 1920-byte R10 from a live capture):
///   ts        u32 LE @ 7
///   accel X/Y/Z  100× int16 LE @ 85 / 285 / 485, scale 1/4096 g
///   gyro  X/Y/Z  100× int16 LE @ 688 / 888 / 1088, scale 0.06103515625 deg/s
/// Returns null if `hex` is not a long-enough R10 frame.
R10Imu? decodeR10Imu(String hex) {
  Uint8List b;
  try {
    b = hexToBytes(hex);
  } catch (_) {
    return null;
  }
  if (b.length < 1288 || b[0] != 0x2b || b[1] != 0x0a) return null;
  final view = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  List<double> axis(int off, double scale) {
    final out = <double>[];
    for (int i = 0; i < 100; i++) {
      out.add(view.getInt16(off + 2 * i, Endian.little) * scale);
    }
    return out;
  }

  return R10Imu(
    ts: view.getUint32(7, Endian.little),
    accelX: axis(85, _accelScale),
    accelY: axis(285, _accelScale),
    accelZ: axis(485, _accelScale),
    gyroX: axis(688, _gyroScale),
    gyroY: axis(888, _gyroScale),
    gyroZ: axis(1088, _gyroScale),
  );
}

/// Raw payload of one live R11 record (inner packet `0x2B`, record type
/// `0x0B`). The signal's MEANING IS UNCONFIRMED — do not read `channelA`/
/// `channelB` as accel, gyro, or PPG. What is established (issue #25, and its
/// self-correction in the same thread): the live region at frame-abs
/// `[36:436]` is 100 plain int32-LE samples, split into two 50-sample
/// channels back to back (not one 100-sample stream, and not the
/// word-swapped-int32 reading first proposed — that reading put a spurious
/// ~56,700 discontinuity at sample 49 that a plain LE read does not have).
/// Accelerometer is ruled out on real captures. A cardiac interpretation is
/// NOT ruled out: an earlier "not cardiac" call from the same misread was
/// itself withdrawn once corrected, and a corrected re-check found suggestive
/// but inconclusive agreement with reference heart rate. Optical baseline or
/// ambient-light channel remain plausible too. This decoder deliberately
/// makes no signal-meaning determination. Effective sample rate is "near
/// 50 Hz per channel", not confirmed to be exactly 50 Hz.
class R11Raw {
  final int ts; // unix seconds (device clock)
  final List<int> channelA; // 50 raw int32 samples, meaning unconfirmed
  final List<int> channelB; // 50 raw int32 samples, meaning unconfirmed
  R11Raw({required this.ts, required this.channelA, required this.channelB});
}

/// Decode a live R11 record's raw two-channel int32 samples. See [R11Raw] for
/// what is and is not established about this frame. Returns null if `hex` is
/// not a long-enough R11 frame.
R11Raw? decodeR11Raw(String hex) {
  Uint8List b;
  try {
    b = hexToBytes(hex);
  } catch (_) {
    return null;
  }
  if (b.length < 436 || b[0] != 0x2b || b[1] != 0x0b) return null;
  final view = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  List<int> channel(int off) {
    final out = <int>[];
    for (int i = 0; i < 50; i++) {
      out.add(view.getInt32(off + 4 * i, Endian.little));
    }
    return out;
  }

  return R11Raw(
    ts: view.getUint32(7, Endian.little),
    channelA: channel(36),
    channelB: channel(236),
  );
}

/// Decode a batch of hex records, returning all surfaceable samples.
List<DecodedSample> decodeBatch(List<String> records) {
  final out = <DecodedSample>[];
  for (final hex in records) {
    final s = decodeRecord(hex);
    if (s != null) out.add(s);
  }
  return out;
}
