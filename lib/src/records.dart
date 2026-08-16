// records.dart — 1:1 Dart port of ts/records.ts.
// Owns the WHOOP historical biometric record decode used by type-47 payloads.
// PURE Dart — dart:typed_data plus constants.dart (itself dependency-free),
// so the packet-type values are not a second copy of the same magic numbers.

import 'dart:typed_data';

import 'constants.dart';

/// Decoded Type-24 historical biometric record.
class R24 {
  final int histVersion; // historical layout version byte @ inner[1] (frame[5])
  final int tsEpoch; // unix seconds @ inner[7:11] (frame[11:15])
  final int tsSubsec; // sub-seconds @ inner[11:13] (frame[15:17], v24/v12)
  final int counter; // record counter @ inner[3:7] (frame[7:11])
  final int hr; // heart rate bpm @ inner[17] (frame[21], v24/v12)

  /// Beat-to-beat (R-R) intervals in ms for this 1 s record, 0–4 of them.
  ///
  /// [rrCount] is the number of intervals we ACCEPTED, i.e. always
  /// `rrIntervalsMs.length` — not the raw declared count byte. A record whose
  /// declared count is implausible (see [kMaxRrPerRecord]) or whose interval
  /// values fall outside [kMinRrMs]..[kMaxRrMs] contributes nothing here rather
  /// than handing HRV a fabricated beat.
  final int rrCount;
  final List<int> rrIntervalsMs;

  /// Raw green-LED PPG ADC count @ inner[29] (frame[33]).
  final int ppgGreen;

  /// A u16 read at inner[31] (frame[35]).
  ///
  /// NOT a red/IR PPG ADC count, despite the name. inner[32:36] is a
  /// well-formed float32 — range 0.005–3.44, finite in all 1887 real v24
  /// records in our parity corpus — so a u16 read at 31 is inner[31] glued to
  /// that float's mantissa LSB. Its high byte is therefore the low bit of an
  /// unrelated quantity, and the value as a whole is noise: it is not a field.
  ///
  /// Kept and still emitted because it is a live column downstream, not
  /// because it means anything. inner[31] alone and the float32 at 32 are both
  /// in [rawTail] (which starts at inner[13], so they are at rawTail bytes 18
  /// and 19:23) — neither is named here, because we do not know what either is.
  @Deprecated(
    'Not a PPG channel: a u16 at inner[31] straddles the float32 at '
    'inner[32:36], so its high byte is that float\'s mantissa LSB and the '
    'value is noise. Do not derive anything from it. The underlying bytes are '
    'available via rawTail.',
  )
  final int ppgRedIr;

  /// Gravity/accel vector (g), 3x float32 @ inner[36:48] (frame[40:52]),
  /// rounded to 4 decimals.
  ///
  /// The record carries this vector TWICE: inner[52:64] is byte-identical to
  /// inner[36:48] in all 1887 real v24 records in our parity corpus. There is
  /// no second vector to decode, so there is no second field.
  ///
  /// The magnitude is NOT calibrated to 1 g. Over those same records |accelG|
  /// averages 1.046 — about 4.6% high — so anything treating it as absolute g
  /// inherits that bias; treat it as a relative motion vector. We deliberately
  /// do NOT apply a correction factor here: a scale derived from one corpus
  /// would be a fabricated calibration, and it would silently move every value
  /// downstream code has already stored.
  final List<double> accelG;

  /// The u8 at inner[51] (frame[55]).
  ///
  /// NOT a contact quality, and NOT a 0–198 scale. inner[48:52] is a float32:
  /// integer-valued, ranging ±32608, with inner[48] zero in all 1887 real v24
  /// records in our parity corpus. inner[51] is that float's sign+exponent
  /// byte — which is exactly why the "quality" only ever takes the values
  /// {0, 63–70, 194–198}. Those are IEEE-754 exponents, not a measurement.
  ///
  /// Kept and still emitted because it is a live column downstream. Do not
  /// threshold it, plot it as quality, or infer wear state from it.
  @Deprecated(
    'Not a contact quality: inner[51] is the sign+exponent byte of the float32 '
    'at inner[48:52], which is why its only observed values are {0, 63-70, '
    '194-198}. There is no contact-quality field here to point at.',
  )
  final int skinContact;

  /// Raw red-channel ADC @ inner[64] (frame[68], WHOOP 4 v24/v12).
  ///
  /// WARNING — [spo2RedRaw] and [spo2IrRaw] are ONE signal, not two channels.
  /// In a real 13-day export, `spo2IrRaw - spo2RedRaw` is a fixed integer
  /// within a capture session: constant across 178 of 300 hours, covering 61%
  /// of a million consecutive rows, while both values drift together. Any
  /// red/IR ratio — and any ratio-of-ratios — built from them therefore
  /// collapses to a function of one channel's baseline drift, and measures
  /// that drift rather than oxygenation. They are published because they ARE
  /// the bytes at those offsets. Do NOT build an SpO2 metric on them.
  ///
  /// Note: WHOOP offsets are often quoted in FRAME-absolute coordinates.
  /// `parseR24` receives the INNER record starting at packet type `0x2f`, so
  /// every frame-absolute offset is 4 bytes lower here. That is why the v24
  /// optical block is 64/66/68/70 in this file but 68/70/72/74 frame-absolute.
  final int spo2RedRaw;

  /// Raw IR-channel ADC @ inner[66] (frame[70], WHOOP 4 v24/v12).
  /// See [spo2RedRaw] — the two are one signal, not a red/IR pair.
  final int spo2IrRaw;

  /// The u16 at inner[68] (frame[72], WHOOP 4 v24/v12).
  ///
  /// NOT a temperature, despite the name. Checked against a 1,047,400-row real
  /// export, it is the noisiest value in this block: it moves 5–10 counts per
  /// second between consecutive 1 Hz samples, while the heart rate carried by
  /// those same records moves 0.72 bpm/s. Skin temperature cannot do that.
  /// Whatever this is, it is some fast optical-block quantity.
  ///
  /// Two genuinely slow, temperature-shaped candidates do exist in this block
  /// — the u16 at inner[72] and inner[88], both ~0.02 counts/s — but neither
  /// is decoded or named here: moving slowly is not evidence of being a
  /// temperature, and naming one would repeat the mistake this field is. Both
  /// are in [rawTail] (which starts at inner[13]) for anyone investigating.
  ///
  /// Kept and still emitted because it is a live column downstream. Do not
  /// convert it to °C, trend it as body temperature, or feed it to a
  /// temperature-based metric.
  @Deprecated(
    'Not skin temperature: this u16 moves ~5-10 counts/second between '
    'consecutive 1 Hz records, which no skin temperature does. No verified '
    'temperature field is known; the slow candidates at inner[72] and '
    'inner[88] are unconfirmed and available via rawTail.',
  )
  final int skinTempRaw;

  /// Raw ambient-light ADC @ inner[70] (frame[74], WHOOP 4 v24/v12).
  final int ambientRaw;

  /// Untouched payload [13:] as hex — kept for re-decode as the map improves.
  ///
  /// Encoded on first read, not at parse time. Nothing in the stack reads it
  /// today, and eagerly hex-encoding 83 bytes per record dominated parseR24's
  /// cost on the offload path.
  String get rawTail => _rawTailHex ??= _hexFrom(_rawTailBytes, 0);
  final Uint8List _rawTailBytes;
  String? _rawTailHex;

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
    required Uint8List rawTailBytes,
  }) : _rawTailBytes = rawTailBytes;

  /// Map matching the TS `out` shape (snake_case keys) for parity comparison.
  ///
  /// The key set is FROZEN: it is checked 1:1 against the golden oracle in
  /// `decode_parity_cases.json`, and it is a shipped SQLite column set
  /// downstream. `ppg_red_ir`, `skin_contact` and `skin_temp_raw` are emitted
  /// here for those two reasons alone — see each field's doc for what the
  /// bytes actually are (and are not). Adding or removing a key breaks both.
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
//
// NaN / ±Infinity are passed through UNCHANGED rather than being folded to 0.0
// (which is what control.dart's `_round` does). Rounding cannot manufacture a
// real number out of a non-finite one: a NaN accel component means the four
// bytes we read are not a float32 field, and silently emitting 0.0 would turn
// "these bytes are not accel" into "the wrist was perfectly still" — a
// fabricated measurement that then propagates through every downstream
// mean/std. control.dart can afford 0.0 because its callers only use it for
// display scalars; here the honest answer is to keep the non-finite value
// visible so [_parseV24Layout] can REJECT the whole record (see the
// `isFinite` gate there), which is an absence the API can already express
// (parseR24 returns null).
double _jsRound(double v) {
  if (!v.isFinite) return v;
  return (v + 0.5).floorToDouble();
}

/// Round `v` to `decimals` places using JS `Math.round(v*p)/p` semantics.
/// Non-finite input is returned unchanged — see [_jsRound].
double _round(double v, int decimals) {
  if (!v.isFinite) return v;
  final p = _pow10(decimals);
  return _jsRound(v * p) / p;
}

/// Largest R-R interval count a single 1 s historical record can plausibly
/// declare. A larger count byte means we are reading the wrong offset — not a
/// second containing dozens of heartbeats. A record declaring more than this
/// yields NO intervals at all (absence), never a truncated read of whatever
/// bytes happen to follow (ppg, accel float32s, spo2, the optical block,
/// ambient).
///
/// This is the HISTORICAL-record ceiling only. live.dart's `realtimeRr` uses
/// it for the R10 form, which declares its count inside a 1920-byte record,
/// but a 0x28 realtime packet is 20 bytes with exactly four R-R slots, so that
/// branch caps at 4 instead — see `realtimeRr`.
const int kMaxRrPerRecord = 8;

/// Physiologically possible beat-to-beat interval bounds, ms — 2500 ms = 24 bpm,
/// 200 ms = 300 bpm. Identical to the bound control.dart's `parseRealtimeHr`
/// applies to the realtime RR slots, so both decoders agree on what a beat is.
const int kMinRrMs = 200;
const int kMaxRrMs = 2500;

/// The historical-record layout versions this package has a field map for.
/// v25 has its own dedicated layout ([_parseV25]); the rest share the v24 field
/// map with a per-version HR offset ([_hrOffsetByVersion]). Used by live.dart's
/// `decodeRecord` so every version [parseR24] can decode is actually routed to
/// it (v12 in particular is real firmware and used to fall through to null,
/// which cost callers the record's own timestamp).
final Set<int> kKnownRecordVersions =
    Set.unmodifiable({..._hrOffsetByVersion.keys, 25});

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
  // The documented v25 layout uses frame-absolute offsets. Our decoder
  // receives the inner record starting at packet type 0x2f, so subtract the
  // 4-byte transport prefix: unix 11->7 and gravity 73/75/77->69/71/73.
  //
  // What is KNOWN for v25:
  //   - unix is stable at inner[7:11]
  //   - gravity is stable at inner[69/71/73] as i16/16384
  // What is NOT solved here:
  //   - exact red/IR scalar offsets inside the v25 optical region
  //   - any true SpO2% decode
  //
  // So v25 intentionally surfaces motion + time only and leaves the optical
  // fields zero rather than inventing a bogus decode.
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
    // COPY, not sublistView: a view aliases the caller's buffer, and rawTail
    // is now encoded lazily, so a later mutation of `inner` would change bytes
    // that were supposed to be a snapshot of parse time.
    rawTailBytes:
        inner.length > 13 ? Uint8List.fromList(inner.sublist(13)) : Uint8List(0),
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
///     plausibility gate — otherwise null). Timing, HR and accel only: the
///     R-R block and the optical block are v24's map and come back absent.
///   - any other version → treated as an unknown/future layout: we attempt the
///     v24 field map and return it only if it is physiologically plausible.
///     This degrades a firmware layout change to a validated best-effort read
///     instead of emitting garbage.
/// Returns null if too short or if the version-specific decode fails.
/// Record types 10 and 11 arrive under BOTH packet types, so the gate is
/// {historical, realtime} — narrowing it to historical alone would break
/// [frameAccel].
bool _isRecordPacket(Uint8List inner) =>
    inner.isNotEmpty &&
    (inner[0] == PacketType.historicalData ||
        inner[0] == PacketType.realtimeData);

R24? parseR24(Uint8List inner) {
  if (inner.length < 2) {
    return null;
  }
  // Every sibling decoder checks inner[0]; this family dispatched purely on
  // inner[1], which on a control frame is the SEQUENCE byte. A sequence of 24
  // or 12 lands on the trusted path, which skips the plausibility gate — so a
  // console-log or command frame whose seq happened to be 24 decoded as a
  // record, with a heart rate and an accel vector read out of log text. Two in
  // 256 of any control frame long enough to try.
  if (!_isRecordPacket(inner)) return null;

  final version = inner[1];
  if (version == 25) return _parseV25(inner);

  // v24 / v12 are our validated map and are trusted verbatim; every other
  // version is a best-effort decode gated on physiological plausibility.
  final trusted = version == 24 || version == 12;
  final hrOffset = _hrOffsetByVersion[version] ?? 17;
  return _parseV24Layout(inner, version, hrOffset: hrOffset, validate: !trusted);
}

/// The original, hardware-validated minimum length for the v24 field map.
/// This is the FIRST thing [FirmwareAwareR24Decoder] tries for every record
/// — it must never be loosened here. (2026-07: a real device was found
/// sending well-formed, otherwise-valid v12 records at only 88 bytes; rather
/// than weaken this validated baseline for everyone, that firmware variant
/// gets its own fallback layout below — see [_shortFrameMinLength] and
/// [FirmwareAwareR24Decoder].)
const int _legacyMinLength = 89;

/// The minimum length actually required to read every field this layout
/// touches — the last one is `ambientRaw`, a u16 at inner[70:72]. Firmware
/// that omits the (apparently unused-by-us) trailing bytes between 72 and 89
/// still decodes correctly against this shorter threshold. Only reached via
/// [FirmwareAwareR24Decoder] AFTER the legacy 89-byte attempt has failed —
/// never used as the default, so devices matching the original validated
/// shape are completely unaffected.
// note: edge's live BLE path pads 88-byte v12 frames up to 89 before it ever
// calls the decoder now, so this tier doesn't actually get hit for that
// anymore - but db.dart / substrate.dart's raw-hex re-derive paths see the
// un-padded bytes directly and still need it. don't remove this thinking
// it's dead, it's just dead for the one case it was originally written for.
const int _shortFrameMinLength = 72;

/// Decode the WHOOP 4 v24 field map with a parameterised HR offset. When
/// [validate] is set the result is returned only if it passes
/// [_physiologicallyPlausible]; otherwise (v24/v12) it is returned verbatim.
/// [minLength] defaults to the original hardware-validated [_legacyMinLength]
/// so every existing direct caller (i.e. [parseR24]) is byte-for-byte
/// unchanged; [FirmwareAwareR24Decoder] is the only caller that passes a
/// shorter fallback value.
R24? _parseV24Layout(
  Uint8List inner,
  int version, {
  required int hrOffset,
  required bool validate,
  int minLength = _legacyMinLength,
}) {
  if (inner.length < minLength) {
    return null;
  }

  final view = inner.buffer.asByteData(
    inner.offsetInBytes,
    inner.lengthInBytes,
  );

  // R-R intervals: rr_count @ [18], then rr_count signed int16 LE from [19].
  //
  // The declared count is UNTRUSTED. Taken raw it addresses up to 255 int16s
  // starting at [19], which walks straight through ppg@29, the accel
  // float32s@36/40/44, the float32@48, spo2@64/66, the u16@68 and
  // ambient@70 — reinterpreting all of them as "beats" that then feed
  // RMSSD/HRV. So: reject an implausible count outright, and accept only
  // values inside the physiological interval range. Both guards run on EVERY
  // path, including the "trusted" v24/v12 one that skips
  // [_physiologicallyPlausible].
  //
  // And they are read ONLY where the v24 field map itself is confirmed. For
  // every other version only the HR offset is established — v7 puts HR at 27
  // and v18 at 14, which is proof the layout differs — so reading rr_count at
  // 18 and intervals from 19 is reading v24's map over bytes known not to be
  // v24's. The range filter cannot save that: it only checks 200..2500 ms, and
  // arbitrary bytes land in range often enough to hand RMSSD a full set of
  // fabricated beats. HR, timing and accel are what the plausibility gate
  // actually evidences; beats are not, so they are absent rather than invented.
  final declaredRrCount = validate ? 0 : inner[18];
  final rrIntervalsMs = <int>[];
  if (declaredRrCount <= kMaxRrPerRecord) {
    for (int i = 0; i < declaredRrCount && 19 + 2 * i + 2 <= inner.length; i++) {
      final v = view.getInt16(19 + 2 * i, Endian.little);
      if (v >= kMinRrMs && v <= kMaxRrMs) rrIntervalsMs.add(v);
    }
  }
  // rrCount reports what we accepted, never what the byte claimed.
  final rrCount = rrIntervalsMs.length;

  final hr = inner[hrOffset];
  final accelG = [
    _round(view.getFloat32(36, Endian.little), 4),
    _round(view.getFloat32(40, Endian.little), 4),
    _round(view.getFloat32(44, Endian.little), 4),
  ];

  // A NaN / ±Infinity accel component means bytes [36:48] are not the float32
  // vector this field map claims. Emitting 0.0 (or the raw NaN) would poison
  // every downstream mean/std with a value that reads as a real measurement,
  // so we reject the record instead — the caller already handles a null decode
  // by archiving the raw bytes. This runs BEFORE the validate gate so it also
  // covers the trusted v24/v12 path, which skips [_physiologicallyPlausible].
  for (final c in accelG) {
    if (!c.isFinite) return null;
  }

  if (validate && !_physiologicallyPlausible(accelG, hr)) {
    return null;
  }

  // The optical block gets the SAME rule as rr_count above: it is v24's field
  // map, so it is read only where that map is confirmed (v24/v12, i.e.
  // !validate). For every other version the plausibility gate evidences HR,
  // timing and accel and nothing else — bytes at 29/31/51/64/66/68/70 on a
  // layout known to differ (v7 puts HR at 27, v18 at 14) are not the optical
  // channels, and feeding them to relative-ODI hands the user a desaturation
  // number computed from unknown bytes. 0 is this stack's ADC-absent sentinel
  // (every consumer gates on `v > 0`), same as _parseV25 already emits.
  final optical = !validate;
  return R24(
    histVersion: version,
    tsEpoch: view.getUint32(7, Endian.little),
    tsSubsec: view.getUint16(11, Endian.little),
    counter: view.getUint32(3, Endian.little),
    hr: hr,
    rrCount: rrCount,
    rrIntervalsMs: rrIntervalsMs,
    ppgGreen: optical ? view.getUint16(29, Endian.little) : 0,
    ppgRedIr: optical ? view.getUint16(31, Endian.little) : 0,
    accelG: accelG,
    skinContact: optical ? inner[51] : 0,
    spo2RedRaw: optical ? view.getUint16(64, Endian.little) : 0,
    spo2IrRaw: optical ? view.getUint16(66, Endian.little) : 0,
    skinTempRaw: optical ? view.getUint16(68, Endian.little) : 0,
    ambientRaw: optical ? view.getUint16(70, Endian.little) : 0,
    // COPY, not sublistView: a view aliases the caller's buffer, and rawTail
    // is now encoded lazily, so a later mutation of `inner` would change bytes
    // that were supposed to be a snapshot of parse time.
    rawTailBytes:
        inner.length > 13 ? Uint8List.fromList(inner.sublist(13)) : Uint8List(0),
  );
}

String _hexFrom(Uint8List b, int start) {
  final sb = StringBuffer();
  for (int i = start; i < b.length; i++) {
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// One decode attempt for a historical-record version, tried in order by
/// [FirmwareAwareR24Decoder]. `name` is diagnostics-only (surfaced via
/// [FirmwareAwareR24Decoder.detectedStrategy]) and has no effect on decode
/// behavior.
class R24DecodeStrategy {
  const R24DecodeStrategy(this.name, this.decode);
  final String name;
  final R24? Function(Uint8List inner) decode;
}

/// The ordered fallback chain [FirmwareAwareR24Decoder] tries for every
/// record version routed through [_parseV24Layout] (i.e. every version
/// except v25, which has its own dedicated layout). Index 0 is always
/// [parseR24] itself — the original, hardware-validated decoder — completely
/// unmodified. Later entries are progressively looser, real-firmware-driven
/// fallbacks: add new ones here (never reorder or remove existing ones)
/// as new firmware variants are identified.
final List<R24DecodeStrategy> _v24FallbackChain = [
  R24DecodeStrategy('legacy_89b', parseR24),
  R24DecodeStrategy('short_frame_72b', (inner) {
    if (inner.length < 2) return null;
    final version = inner[1];
    if (version == 25) return null; // v25 has no known length variant; handled by parseR24 alone.
    final trusted = version == 24 || version == 12;
    final hrOffset = _hrOffsetByVersion[version] ?? 17;
    return _parseV24Layout(
      inner,
      version,
      hrOffset: hrOffset,
      validate: !trusted,
      minLength: _shortFrameMinLength,
    );
  }),
];

/// Firmware-aware, per-session historical-record decoder.
///
/// Different physical WHOOP 4 units have been observed sending the exact
/// same record version at a different wire length than the one we
/// originally validated hardware against (2026-07: a real device sent 11k+
/// consecutive, otherwise-well-formed v12 records at 88 bytes — one under
/// the 89-byte floor [parseR24] requires). Rather than loosen the validated
/// decoder for every device, each record is tried against [_v24FallbackChain]
/// IN ORDER — the original decoder first, newer fallbacks after — and the
/// strategy that first succeeds for a given version byte is remembered so
/// the rest of the session skips straight to it instead of re-probing every
/// record. If every strategy fails, [decode] returns null exactly like
/// [parseR24] would, so the caller's existing "archive as undecodable"
/// handling (raw_archive) is unchanged.
///
/// Construct ONE instance per BLE session/connection (like
/// [FrameReassembler]) — detected-firmware state must not leak across a
/// different physical band pairing.
class FirmwareAwareR24Decoder {
  final Map<int, String> _detectedByVersion = {};

  /// The strategy name detected so far this session, keyed by record version
  /// byte — diagnostics/telemetry only (e.g. surfacing "this band needed the
  /// 72-byte v12 fallback"). Never affects decode behavior.
  Map<int, String> get detectedStrategies => Map.unmodifiable(_detectedByVersion);

  R24? decode(Uint8List inner) {
    if (inner.length < 2) return null;
    if (!_isRecordPacket(inner)) return null; // see parseR24
    final version = inner[1];
    if (version == 25) return parseR24(inner); // no known firmware variant for v25 yet.

    final knownName = _detectedByVersion[version];
    if (knownName != null) {
      final known = _v24FallbackChain.firstWhere(
        (s) => s.name == knownName,
        orElse: () => _v24FallbackChain.first,
      );
      final r = known.decode(inner);
      if (r != null) return r;
      // The previously-detected strategy stopped working for this record
      // (e.g. a mid-session firmware update, or one anomalous frame) — fall
      // through and re-probe the full chain below rather than permanently
      // failing every subsequent record from this version.
    }

    for (final strategy in _v24FallbackChain) {
      final r = strategy.decode(inner);
      if (r != null) {
        _detectedByVersion[version] = strategy.name;
        return r;
      }
    }
    return null; // every strategy failed — caller archives as undecodable, as before.
  }
}

// ── gen5 (WHOOP 5) historical records ───────────────────────────────────────
//
// SUPERSEDED (2026-08, multiband port): this file used to also own a
// `parseGen5Record` targeting `_gen5NormalHistoryVersions = {9, 12, 24}`.
// That version set is WRONG — 9/12/24 are WHOOP4's thin/rich HR-only and
// full-optical layouts, not anything a real WHOOP 5.0/MG strap ships. Both
// independent reference implementations (whoop-rs, hardware-tested; noop,
// tens of thousands of captured records across multiple straps/firmware
// builds) agree that real gen5 historical data (packet type 0x2F) ships
// hist_version bytes 18, 20, 21, 26 — never 9/12/24. Running gen5 bytes
// through this file's v24 field map (which is what the old `parseGen5Record`
// effectively did, gated down to just the HR byte) reads all-zero garbage on
// real captures — exactly the symptom this file's old doc comment described,
// which was itself the tell that the version set was wrong, not that gen5's
// 1 Hz record is "deliberately thin".
//
// The real decoders now live in gen5_records.dart: [parseGen5Historical]
// dispatches to the v18 (per-second biometric summary — the actual gen5
// analogue of this file's R24/v24), v20 (optical deep buffer), v21 (IMU deep
// buffer), and v26 (PPG waveform) decoders. See that file for the full field
// maps and the byte-level verification behind them.
