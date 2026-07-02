// records.dart — 1:1 Dart port of ts/records.ts.
// Owns the Type-24 historical biometric record (96 bytes, 1 Hz) decode.
// PURE Dart — dart:typed_data only.

import 'dart:typed_data';

/// Decoded Type-24 historical biometric record.
class R24 {
  final int histVersion; // historical layout version byte @ [1]
  final int tsEpoch; // unix seconds @ [7:11]
  final int tsSubsec; // sub-seconds @ [11:13]
  final int counter; // record counter @ [3:7]
  final int hr; // heart rate bpm @ [17]

  /// Beat-to-beat (R-R) intervals in ms for this 1 s record, 0–4 of them.
  final int rrCount;
  final List<int> rrIntervalsMs;

  /// Raw green-LED PPG ADC count @ [29].
  final int ppgGreen;

  /// Raw red/IR-LED PPG ADC count @ [31].
  final int ppgRedIr;

  /// Gravity/accel vector (g), 3× float32 @ [36:48], rounded to 4 decimals.
  final List<double> accelG;

  /// Skin-contact quality @ [51] (u8, 0–198).
  final int skinContact;

  /// Raw red-channel ADC @ [64] (relative).
  final int spo2RedRaw;

  /// Raw IR-channel ADC @ [66] (relative).
  final int spo2IrRaw;

  /// Raw skin-temperature ADC @ [68] (relative).
  final int skinTempRaw;

  /// Raw ambient-light ADC @ [70] (relative).
  final int ambientRaw;

  /// Untouched payload [13:] as hex — kept for re-decode as the map improves.
  final String rawTail;

  R24({
    required this.histVersion,
    required this.tsEpoch,
    required this.tsSubsec,
    required this.counter,
    required this.hr,
    required this.rrCount,
    required this.rrIntervalsMs,
    required this.ppgGreen,
    required this.ppgRedIr,
    required this.accelG,
    required this.skinContact,
    required this.spo2RedRaw,
    required this.spo2IrRaw,
    required this.skinTempRaw,
    required this.ambientRaw,
    required this.rawTail,
  });

  /// Map matching the TS `out` shape (snake_case keys) for parity comparison.
  Map<String, dynamic> toMap() => {
        'ts_epoch': tsEpoch,
        'ts_subsec': tsSubsec,
        'counter': counter,
        'hr': hr,
        'rr_count': rrCount,
        'rr_intervals_ms': rrIntervalsMs,
        'ppg_green': ppgGreen,
        'ppg_red_ir': ppgRedIr,
        'accel_g': accelG,
        'skin_contact': skinContact,
        'spo2_red_raw': spo2RedRaw,
        'spo2_ir_raw': spo2IrRaw,
        'skin_temp_raw': skinTempRaw,
        'ambient_raw': ambientRaw,
        'raw_tail': rawTail,
      };
}

// Replicate JavaScript Math.round semantics: round half toward +Infinity
// (Math.round(2.5)=3, Math.round(-2.5)=-2). Dart's roundToDouble rounds half
// away from zero, so we implement the JS rule explicitly.
double _jsRound(double v) => (v + 0.5).floorToDouble();

/// Round `v` to `decimals` places using JS `Math.round(v*p)/p` semantics.
double _round(double v, int decimals) {
  final p = _pow10(decimals);
  return _jsRound(v * p) / p;
}

double _pow10(int n) {
  double p = 1;
  for (int i = 0; i < n; i++) {
    p *= 10;
  }
  return p;
}

ByteData _view(Uint8List b) =>
    b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);

double _gravI16(Uint8List inner, int offset) {
  final v = _view(inner).getInt16(offset, Endian.little);
  return _round(v / 16384.0, 4);
}

R24? _parseV25(Uint8List inner) {
  if (inner.length < 75) return null;
  final view = _view(inner);
  // The documented v25 layout uses absolute frame offsets. Our decoder
  // receives the inner record starting at packet type 0x2f, so subtract the
  // 4-byte transport prefix: unix 11->7 and gravity 73/75/77->69/71/73.
  final gx = _gravI16(inner, 69);
  final gy = _gravI16(inner, 71);
  final gz = _gravI16(inner, 73);
  final mag = (gx * gx + gy * gy + gz * gz);
  if (mag < 0.25 || mag > 2.25) return null; // ~0.5g..1.5g
  return R24(
    histVersion: 25,
    tsEpoch: view.getUint32(7, Endian.little),
    tsSubsec: 0,
    counter: view.getUint32(3, Endian.little),
    hr: 0,
    rrCount: 0,
    rrIntervalsMs: const [],
    ppgGreen: 0,
    ppgRedIr: 0,
    accelG: [gx, gy, gz],
    skinContact: 0,
    spo2RedRaw: 0,
    spo2IrRaw: 0,
    skinTempRaw: 0,
    ambientRaw: 0,
    rawTail: _hexFrom(inner, 13),
  );
}

/// Decode a WHOOP 4 historical biometric record. `inner` starts at the
/// packet-type byte. Auto-routes supported layout versions (`24`, `25`).
/// Returns null if too short or if the version-specific decode fails.
R24? parseR24(Uint8List inner) {
  if (inner.length < 2) {
    return null;
  }

  final version = inner[1];
  if (version == 25) return _parseV25(inner);
  if (version != 24 && version != 12) {
    return null;
  }
  if (inner.length < 89) {
    return null;
  }

  final view = inner.buffer.asByteData(
    inner.offsetInBytes,
    inner.lengthInBytes,
  );

  // R-R intervals: rr_count @ [18], then rr_count signed int16 LE from [19].
  final rrCount = inner[18];
  final rrIntervalsMs = <int>[];
  for (int i = 0; i < rrCount && 19 + 2 * i + 2 <= inner.length; i++) {
    final v = view.getInt16(19 + 2 * i, Endian.little);
    if (v > 0) rrIntervalsMs.add(v);
  }

  return R24(
    histVersion: version,
    tsEpoch: view.getUint32(7, Endian.little),
    tsSubsec: view.getUint16(11, Endian.little),
    counter: view.getUint32(3, Endian.little),
    hr: inner[17],
    rrCount: rrCount,
    rrIntervalsMs: rrIntervalsMs,
    ppgGreen: view.getUint16(29, Endian.little),
    ppgRedIr: view.getUint16(31, Endian.little),
    accelG: [
      _round(view.getFloat32(36, Endian.little), 4),
      _round(view.getFloat32(40, Endian.little), 4),
      _round(view.getFloat32(44, Endian.little), 4),
    ],
    skinContact: inner[51],
    spo2RedRaw: view.getUint16(64, Endian.little),
    spo2IrRaw: view.getUint16(66, Endian.little),
    skinTempRaw: view.getUint16(68, Endian.little),
    ambientRaw: view.getUint16(70, Endian.little),
    rawTail: _hexFrom(inner, 13),
  );
}

String _hexFrom(Uint8List b, int start) {
  final sb = StringBuffer();
  for (int i = start; i < b.length; i++) {
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
