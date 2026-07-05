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

/// Decode a v25 (PPG-derived) historical record. Unlike v24, the v25 field map
/// comes purely from our own device captures — it has no independent
/// cross-reference, so it is LOWER-CONFIDENCE: we decode timing + gravity and
/// deliberately leave HR at 0 (v25 carries no honest 1 Hz beat). It is gated on
/// a gravity-magnitude sanity check to avoid emitting garbage.
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

/// HR-byte offset within the record inner, keyed by the layout version byte
/// (inner[1]). The header (counter @ [3], ts @ [7], subsec @ [11]) is shared
/// across versions; only the HR byte moves. Established from our own hardware
/// captures across the layout versions the strap has served us.
const Map<int, int> _hrOffsetByVersion = {
  7: 27,
  9: 17,
  12: 17,
  18: 14,
  24: 17,
};

/// Physiological plausibility gate for a best-effort decode: the gravity vector
/// must have magnitude ≈ 1 g (0.5–1.8 g) AND HR must be in a live human range
/// (25–230 bpm). Used to guard speculative decodes (unrecognised versions, or
/// versions where only the HR offset — not the full field map — is confirmed).
/// Compared on magnitude-squared to avoid a sqrt.
bool _physiologicallyPlausible(List<double> accelG, int hr) {
  if (hr < 25 || hr > 230) return false;
  if (accelG.length != 3) return false;
  final magSq = accelG[0] * accelG[0] +
      accelG[1] * accelG[1] +
      accelG[2] * accelG[2];
  return magSq >= 0.25 && magSq <= 3.24; // 0.5 g .. 1.8 g
}

/// Decode a WHOOP 4 historical biometric record. `inner` starts at the
/// packet-type byte.
///
/// Routing:
///   - v25 → the PPG-derived layout ([_parseV25]).
///   - v24 / v12 → our hardware-validated field map, returned as-is.
///   - v18 / v9 / v7 → the SAME field map but with the HR byte read at that
///     version's offset (only the HR offset is independently confirmed for
///     these, so the decode is returned only if it passes a physiological
///     plausibility gate — otherwise null).
///   - any other version → treated as an unknown/future layout: we attempt the
///     v24 field map and return it only if it is physiologically plausible.
///     This degrades a firmware layout change to a validated best-effort read
///     instead of emitting garbage.
///
/// Returns null if too short or if the version-specific decode fails.
R24? parseR24(Uint8List inner) {
  if (inner.length < 2) {
    return null;
  }

  final version = inner[1];
  if (version == 25) return _parseV25(inner);

  // v24 / v12 are our validated map and are trusted verbatim; every other
  // version is a best-effort decode gated on physiological plausibility.
  final trusted = version == 24 || version == 12;
  final hrOffset = _hrOffsetByVersion[version] ?? 17;
  return _parseV24Layout(inner, version, hrOffset: hrOffset, validate: !trusted);
}

/// Decode the WHOOP 4 v24 field map with a parameterised HR offset. When
/// [validate] is set the result is returned only if it passes
/// [_physiologicallyPlausible]; otherwise (v24/v12) it is returned verbatim.
R24? _parseV24Layout(
  Uint8List inner,
  int version, {
  required int hrOffset,
  required bool validate,
}) {
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

  final hr = inner[hrOffset];
  final accelG = [
    _round(view.getFloat32(36, Endian.little), 4),
    _round(view.getFloat32(40, Endian.little), 4),
    _round(view.getFloat32(44, Endian.little), 4),
  ];

  if (validate && !_physiologicallyPlausible(accelG, hr)) {
    return null;
  }

  return R24(
    histVersion: version,
    tsEpoch: view.getUint32(7, Endian.little),
    tsSubsec: view.getUint16(11, Endian.little),
    counter: view.getUint32(3, Endian.little),
    hr: hr,
    rrCount: rrCount,
    rrIntervalsMs: rrIntervalsMs,
    ppgGreen: view.getUint16(29, Endian.little),
    ppgRedIr: view.getUint16(31, Endian.little),
    accelG: accelG,
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
