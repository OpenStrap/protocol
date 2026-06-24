// live.dart — 1:1 Dart port of ts/live.ts.
// Live + IMU frame decoders (R10/0x28/0x33/R24 dispatch, IMU accel magnitudes,
// realtime RR, R10 motion activity + autocorrelation steps).
// PURE Dart — dart:typed_data + dart:math only.

import 'dart:math' as math;
import 'dart:typed_data';

import 'records.dart';

/// A decoded HR/activity sample.
class DecodedSample {
  final int ts; // unix seconds
  final int hr; // bpm (0 = off-wrist / no reading)
  final double activity; // motion magnitude (stddev of |accel(g)|), 0 if no IMU
  final int stepsInc; // steps detected in this record's IMU window (R10 only)
  final bool wristOn; // worn proxy (hr>0)
  final int recType; // 10 | 24 | 28

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
  ImuFrame(this.ts, this.idx, this.mags);

  Map<String, dynamic> toMap() => {'ts': ts, 'idx': idx, 'mags': mags};
}

Uint8List hexToBytes(String hex) {
  final trimmed = hex.trim();
  final out = Uint8List(trimmed.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
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
    for (int i = 0; i < 10; i++) {
      final x = view.getInt16(24 + 2 * i, Endian.little);
      final y = view.getInt16(24 + 2 * (10 + i), Endian.little);
      final z = view.getInt16(24 + 2 * (20 + i), Endian.little);
      mags.add(math.sqrt(x * x + y * y + z * z) / 4096);
    }
    return ts > 0 ? ImuFrame(ts, idx, mags) : null;
  }
  // R10: rec 0x0A, ts@7, accel X@85/Y@285/Z@485 (100 int16 each).
  if (rec == 0x0a && b.length >= 685) {
    final ts = view.getUint32(7, Endian.little);
    final mags = <double>[];
    for (int i = 0; i < 100; i++) {
      final x = view.getInt16(85 + 2 * i, Endian.little);
      final y = view.getInt16(285 + 2 * i, Endian.little);
      final z = view.getInt16(485 + 2 * i, Endian.little);
      mags.add(math.sqrt(x * x + y * y + z * z) / 4096);
    }
    return ts > 0 ? ImuFrame(ts, 0, mags) : null;
  }
  return null;
}

/// Beat-to-beat (R-R) intervals (ms) from the live records that carry them.
///   • 0x28 REALTIME_DATA (compact HR): rr_count u8 @ [9],  rr i16 LE @ [10 + 2i]
///   • R10  (rec_type 10):              rr_count u8 @ [18], rr i16 LE @ [19 + 2i]
/// Returns {ts, rr_ms} or null.
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
  int tsOff, cntOff;
  if (pkt == 0x28) {
    tsOff = 2;
    cntOff = 9;
  } else if (rec == 10) {
    tsOff = 7;
    cntOff = 18;
  } else {
    return null;
  }
  if (cntOff + 1 >= b.length) return null;
  final ts = view.getUint32(tsOff, Endian.little);
  if (ts <= 0) return null;
  final n = b[cntOff];
  if (n == 0 || n > 8) return null; // realtime carries 0–4; large count = wrong offset
  final rrMs = <int>[];
  final first = cntOff + 1;
  for (int i = 0; i < n && first + 2 * i + 2 <= b.length; i++) {
    final v = view.getInt16(first + 2 * i, Endian.little);
    if (v > 0) rrMs.add(v);
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
_Motion _r10Motion(ByteData view, int len) {
  if (len < 685) return _Motion(0, 0);
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
  if (n == 0) return _Motion(0, 0);
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
        ts: ts, hr: hr, activity: 0, stepsInc: 0, wristOn: hr > 0, recType: 28);
  }

  // 0x33 — live IMU stream: raw-only (no sample emitted).
  if (pktType == 0x33) return null;

  if (b.length < 18) return null;

  // R24 — type-24 historical telemetry.
  if (recType == 24) {
    final d = parseR24(b);
    if (d == null) return null;
    return DecodedSample(
        ts: d.tsEpoch,
        hr: d.hr,
        activity: 0,
        stepsInc: 0,
        wristOn: d.hr > 0,
        recType: 24);
  }

  // R10 / 0x2B — ts@7, hr@17, IMU arrays → activity.
  if (recType == 10) {
    final ts = view.getUint32(7, Endian.little);
    final hr = b[17];
    final m = _r10Motion(view, b.length);
    return DecodedSample(
        ts: ts,
        hr: hr,
        activity: m.activity,
        stepsInc: m.steps,
        wristOn: hr > 0,
        recType: 10);
  }

  return null;
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
