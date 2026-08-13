// gen5_records.dart — WHOOP 5 (gen5 / "fd4b" / "Maverick-Goose") historical
// record decoders: v18 (per-second biometric summary), v20 (raw optical deep
// buffer, 5 AFE channels × 2 photodiodes), v21 (100Hz 6-axis IMU deep buffer),
// v26 (24-SAMPLE PPG waveform — 24 is a sample count, not a rate; the rate is
// whatever PPG rate the record's own flags byte declares, see
// [Gen5HistoricalRecord.ppgSampleRateHz]).
//
// REPLACES `records.dart`'s old `parseGen5Record` / `_gen5NormalHistoryVersions
// = {9, 12, 24}`, which targeted the WRONG version set (those are WHOOP4's
// thin/rich HR-only and full-optical layouts, not anything gen5 ships). Real
// WHOOP 5.0/MG historical data (packet type 0x2F) ships hist_version bytes
// 18, 20, 21, 26 — the VERSION SET is confirmed independently by whoop-rs
// (Rust, hardware-tested) and noop (Swift, multiple straps/firmware builds),
// and v18/v21/v26's FIELD LAYOUTS are independently re-verified byte-by-byte
// here against real fixtures (CRC16 + CRC32 both checked) — see
// gen5_historical_test.dart for the golden parity tests.
//
// v20's geometry (body start, block stride, slot offsets, sign-extended 20-bit
// samples) and its per-block metadata are confirmed too — see
// [Gen5OpticalBuffer].
//
// KEY FACT this whole file leans on: gen5's INNER-relative field offsets are
// IDENTICAL to gen4's / to the frame-absolute offsets many sources quote,
// minus the header-length delta. Concretely: frame-absolute offset X on a
// gen5 frame == `inner[X - 8]` (gen5's header is 8 bytes; `inner` is what
// [Frame.inner] / `parseFrame` already hands you post header-strip). Every
// offset below is written as `frameAbsolute - 8` and cross-checked against a
// real, CRC-valid capture.
//
// PURE Dart — dart:typed_data only.

import 'dart:typed_data';

import 'records.dart' show kMinRrMs, kMaxRrMs;

ByteData _view(Uint8List b) =>
    b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);

/// Round `v` to `decimals` places (JS `Math.round(v*p)/p` semantics, half
/// toward +Infinity). Non-finite input passed through unchanged — see
/// records.dart's `_jsRound` doc for why: folding NaN to 0.0 here would turn
/// "these bytes are not the field this map claims" into a fabricated reading.
double _round(double v, int decimals) {
  if (!v.isFinite) return v;
  double p = 1;
  for (int i = 0; i < decimals; i++) {
    p *= 10;
  }
  return ((v * p) + 0.5).floorToDouble() / p;
}

// ── Shared historical-record header (§1.5's "shared v18/v20/v21/v26 header
// convention") — a cheap, version-byte-independent dispatch key. ───────────

/// The 13-byte header every gen5 historical record kind (v18/v20/v21/v26)
/// shares, at INNER offsets `[0:13)`:
/// ```
///   inner[0]      packet type (0x2F)
///   inner[1]      hist_version   (frame-abs 9)
///   inner[2]      flags          (frame-abs 10) — see [flags]
///   inner[3:7]    record_index   u32 LE (frame-abs 11) — monotonic, not unix
///   inner[7:11]   unix           u32 LE (frame-abs 15)
///   inner[11:13]  sub-second     u16 LE (frame-abs 19) — Q15, see [tsSubsec]
/// ```
class Gen5HistoricalHeader {
  final int version;

  /// inner[2], a bit field — NOT an opaque layout tag.
  ///
  /// - bit 7: the optical front end is running at 25 Hz (clear = 50 Hz). See
  ///   [ppgSampleRateHz]; nothing else on the wire carries the rate, so this
  ///   bit is what makes an optical record self-describing.
  /// - bit 1 (v18) and bit 0 (v20) are separate real flags. v20's bit 0 marks
  ///   the IR-channel fallback described on [Gen5OpticalBuffer].
  ///
  /// Exposed raw so callers can read bits this decoder does not name.
  final int flags;
  final int recordIndex;
  final int unix;

  /// Raw sub-second at inner[11:13], a Q15 fraction of a second
  /// (`tsSubsec / 32768`, see [subSecond]) — the same field gen4's R24 exposes
  /// as `tsSubsec`. Null only when [inner] was too short to carry it.
  final int? tsSubsec;

  const Gen5HistoricalHeader({
    required this.version,
    required this.flags,
    required this.recordIndex,
    required this.unix,
    required this.tsSubsec,
  });

  @Deprecated('inner[2] is a flags byte, not an opaque marker — use flags')
  int get layoutMarker => flags;

  /// Optical sample rate this record was captured at, in Hz — bit 7 of
  /// [flags].
  int get ppgSampleRateHz => (flags & 0x80) != 0 ? 25 : 50;

  /// [tsSubsec] as seconds in [0, 1), or null on a header too short to carry
  /// it.
  double? get subSecond {
    final raw = tsSubsec;
    return raw == null ? null : raw / 32768.0;
  }

  static Gen5HistoricalHeader? tryParse(Uint8List inner) {
    if (inner.length < 11) return null;
    final v = _view(inner);
    return Gen5HistoricalHeader(
      version: inner[1],
      flags: inner[2],
      recordIndex: v.getUint32(3, Endian.little),
      unix: v.getUint32(7, Endian.little),
      tsSubsec: inner.length >= 13 ? v.getUint16(11, Endian.little) : null,
    );
  }
}

/// Base type every decoded gen5 historical record kind extends. Callers that
/// don't care which kind they got can still read the shared header fields.
abstract class Gen5HistoricalRecord {
  final int histVersion;

  /// inner[2] — see [Gen5HistoricalHeader.flags].
  final int flags;
  final int recordIndex;
  final int unix;

  /// Sub-second of [unix], Q15 (`tsSubsec / 32768`) — see [subSecond]. Every
  /// record kind carries it; gen4's R24 exposes the same field.
  final int tsSubsec;

  const Gen5HistoricalRecord({
    required this.histVersion,
    required this.flags,
    required this.recordIndex,
    required this.unix,
    required this.tsSubsec,
  });

  @Deprecated('inner[2] is a flags byte, not an opaque marker — use flags')
  int get layoutMarker => flags;

  /// Optical sample rate this record was captured at, in Hz — bit 7 of
  /// [flags] (set = 25 Hz, clear = 50 Hz).
  int get ppgSampleRateHz => (flags & 0x80) != 0 ? 25 : 50;

  /// [tsSubsec] as seconds in [0, 1). Add to [unix] for the true sample time.
  double get subSecond => tsSubsec / 32768.0;
}

// ── v18 — per-second biometric summary (the gen5 analogue of gen4's v24;
// this is the record that actually ships as gen5's "1 Hz" history). ────────

/// The band's own coarse wake/sleep state, from bits 4-5 of
/// [Gen5HistorySample.sleepStateByte] (frame-abs 81).
///
/// Two things to know before consuming it:
///
/// - **It is an envelope, not a stage.** Deep, light and REM all read as
///   [sleep], so it carries no in-sleep stage information.
/// - **[sleep] lags true onset** by roughly ten minutes — the band wants a
///   sustained stretch of stillness before it commits.
enum Gen5SleepState {
  /// Nibble 0. Awake/active — the highest-motion, highest-HR state.
  wake,

  /// Nibble 1. Settling: still, but not yet declared asleep. The only path
  /// from [wake] to [sleep].
  still,

  /// Nibble 2. The band has declared sleep. Lowest motion, lowest HR.
  sleep,

  /// Nibble 3. Out of bed / arousal. Reachable only from [sleep].
  up,
}

/// Decoded gen5 v18 historical record. Field confidence/status is annotated
/// per-field below — several fields have OPEN semantic disagreements between
/// the two reference implementations (whoop-rs vs noop) that could not be
/// resolved from bytes alone; those are called out explicitly rather than
/// silently picking a side.
class Gen5HistorySample extends Gen5HistoricalRecord {
  /// bpm. 0 is a legitimate reading (device warming up), not absence.
  final int heartRate;

  /// Number of R-R intervals we ACCEPTED (see [rrIntervalsMs] doc) — always
  /// `rrIntervalsMs.length`, never the raw declared count byte, mirroring
  /// records.dart's R24 convention.
  final int rrCount;
  final List<int> rrIntervalsMs;

  /// Raw @ inner[25] (frame-abs 33). whoop-rs calls this offset
  /// "signal_flags"; the meaning is otherwise unconfirmed. Exposed raw.
  final int cardiacFlags;

  /// @ inner[28] (frame-abs 36). bit7 = HR/RR-valid this second (gates
  /// whether [heartRateAlt] should be trusted); the low 4 bits are a separate
  /// small field — see [hrQualityCounter].
  ///
  /// NOT the low half of a fixed-point heart rate. **bit4 is never set** — 0
  /// of 2,663,358 records across two bands — and a fractional byte cannot
  /// have a structurally dead bit. The low 4 bits are a separate field,
  /// uniform over 0..15; bits 5-7 are flags.
  final int hrQualityFlags;

  /// Low 4 bits of [hrQualityFlags] — a small field, uniform over 0..15,
  /// independent of bit7. Purpose unknown; exposed for diagnostics only.
  int get hrQualityCounter => hrQualityFlags & 0x0F;

  /// Second heart-rate byte @ inner[29] (frame-abs 37).
  ///
  /// Not the near-duplicate of [heartRate] this was previously documented as:
  /// it agrees 58-64% of the time, rising to 67-75% when
  /// [hrRrValidThisSecond]. The gate is real, but even gated this is a
  /// corroboration signal — do not substitute it for [heartRate].
  final int heartRateAlt;

  /// @ inner[30:32] (frame-abs 38). Meaning UNPINNED — exposed raw, do not
  /// consume as a decoded value yet.
  final int rrPacked;

  /// @ inner[32] (frame-abs 40). Meaning still unpinned. whoop-rs calls it
  /// "signal_quality" and gates an HR-anomaly check on `>=192` — that gate
  /// passes 96.7% of records and its rejections don't track [sleepState]
  /// consistently between bands, so it is not doing what it looks like.
  ///
  /// Exposed raw ONLY. Do NOT wire an HR-anomaly gate off this byte.
  final int cardiacStatusRaw;

  /// Gravity-removed motion magnitude (g) @ inner[33:37] f32 LE (frame-abs
  /// 41). Gated finite ∈ [0, 8] at decode time (see [Gen5V18Decoder]).
  final double dynamicAccelerationG;

  /// [x, y, z] (g) @ inner[37/41/45] f32 LE each (frame-abs 45/49/53). Gated
  /// finite with magnitude ∈ [0.5, 1.8] g at decode time — the same window
  /// gen4 uses. These are per-axis means of raw accel, not a normalised
  /// vector, so a worn strap in motion legitimately reads above 1 g; do not
  /// re-reject on a tighter bound than the decoder already applies.
  final List<double> gravityG;

  /// Cumulative on-chip step counter @ inner[49:51] u16 LE (frame-abs 57).
  /// FULL 2 bytes — an earlier bug (fixed upstream, noop #132/#276) read
  /// only the low byte. No midnight reset.
  final int stepMotionCounter;

  /// Raw @ inner[51] u8 (frame-abs 59). inner[52] is a hard zero, so a u16 read
  /// here happens to give the same number — but the field is one byte.
  final int stepCadence;

  /// RAW byte @ inner[55] (frame-abs 63). Only 0 / 1 (walk) / 2 (run) are
  /// valid activity-class codes — everything else (0xFF, 7, ...) is the strap
  /// signaling "not classified", not a fourth activity. Kept as the raw byte
  /// for diagnostics; use [activityClassKnown] for the honest, gated value
  /// (never fabricate a class out of an invalid code).
  ///
  /// **Code 0 means unknown/unclassified, NOT "still".** It is the code the
  /// band emits before it has committed to a class, so a run of 0s is an
  /// absence of classification, not a stretch of stillness — do not count it
  /// as sedentary time. (0 is still a *valid* code, hence
  /// [activityClassKnown] admitting it: "the band says it doesn't know" is
  /// information; 0xFF is a malformed field.)
  final int activityClass;

  /// [activityClass] gated to the 3 known-valid codes, null otherwise — the
  /// honest getter callers should actually use.
  int? get activityClassKnown =>
      (activityClass == 0 || activityClass == 1 || activityClass == 2)
          ? activityClass
          : null;

  /// °C = raw/10. @ inner[61:63] i16 LE (frame-abs 69).
  final double tempAux1C;

  /// °C = raw/10. @ inner[63:65] i16 LE (frame-abs 71).
  final double tempAux2C;

  /// °C = raw/100 — a GEN5-SPECIFIC scale; do NOT reuse gen4's per-device
  /// affine scale here. @ inner[65:67] **i16** LE (frame-abs 73). Signed: an
  /// unsigned read turns anything below 0 °C into ≈ +655 °C. Confirmed
  /// worn≈30.6°C / off-wrist≈22.5°C on real captures.
  final double skinTempC;

  /// Raw, not deep-sleep markers per noop. @ inner[67/69/71] u16 LE each
  /// (frame-abs 75/77/79).
  final int statusWord;
  final int statusWord1;
  final int statusWord2;

  /// Raw @ inner[73] (frame-abs 81). FOUR packed 2-bit fields:
  ///   bits 0-1: on-wrist
  ///   bits 2-3: wake_quality
  ///   bits 4-5: sleep_state — 0 wake / 1 still / 2 sleep / 3 up. Prefer
  ///     [sleepState] over reading the nibble yourself. whoop-rs's
  ///     "0 still / 1 wake" is the wrong way round.
  ///   bits 6-7: a fourth 2-bit field, real but unnamed — see [bits67Raw].
  final int sleepStateByte;

  /// @ inner[74] (frame-abs 82). Opaque, sleep-gated. Do NOT surface it as a
  /// metric — there is no validity signal to gate it on.
  ///
  /// It reads 0 in 99% of records and is *identically* zero unless
  /// [sleepState] is [Gen5SleepState.sleep], where it fires on 2.4% of
  /// records, clustering at 95-99. That distribution does not disqualify a
  /// blood-oxygen reading on this band — the measurement is itself sleep-gated
  /// — so treat "is it SpO2" as open rather than settled either way. Values
  /// above 128 decompose as `128 + <a value from the low set>`, so bit 7 looks
  /// like a flag rather than part of the number.
  final int spo2CandidateRaw;

  /// @ inner[98:100] (frame-abs 106) — ONE **big-endian** u16, not two bytes.
  /// A zero low byte means off-wrist.
  final int opticalBaseline;

  /// @ inner[100:102] (frame-abs 108) — ONE **big-endian** u16. The value
  /// 0x8080 is a signal-quality sentinel rather than a real amplitude — see
  /// [isOpticalAmpSentinel]. (Read as two bytes it looks like "128 on both
  /// halves at once", which is what it was previously mistaken for.)
  final int opticalAmp;

  /// High byte of [opticalBaseline].
  @Deprecated('inner[98:100] is one big-endian u16 — use opticalBaseline')
  int get opticalBaselineA => opticalBaseline >> 8;

  /// Low byte of [opticalBaseline].
  @Deprecated('inner[98:100] is one big-endian u16 — use opticalBaseline')
  int get opticalBaselineB => opticalBaseline & 0xFF;

  /// High byte of [opticalAmp].
  @Deprecated('inner[100:102] is one big-endian u16 — use opticalAmp')
  int get opticalAmpA => opticalAmp >> 8;

  /// Low byte of [opticalAmp].
  @Deprecated('inner[100:102] is one big-endian u16 — use opticalAmp')
  int get opticalAmpB => opticalAmp & 0xFF;

  /// @ inner[105:109] f32 LE (frame-abs 113). A per-second signal-quality
  /// metric the band's own optical processing computes: the log-variance of
  /// the signal it measured this second. Range ~-5.3..0 on the reference
  /// corpus — lower is a quieter, cleaner signal.
  ///
  /// Usable as a quality weight (e.g. to down-weight a second's HR/RR), which
  /// is what it is for. The absolute scale is the band's, not a physical unit,
  /// so compare it against other seconds, not against a threshold you invent.
  final double signalQualityLogVariance;

  const Gen5HistorySample({
    required super.histVersion,
    required super.flags,
    required super.recordIndex,
    required super.unix,
    required super.tsSubsec,
    required this.heartRate,
    required this.rrCount,
    required this.rrIntervalsMs,
    required this.cardiacFlags,
    required this.hrQualityFlags,
    required this.heartRateAlt,
    required this.rrPacked,
    required this.cardiacStatusRaw,
    required this.dynamicAccelerationG,
    required this.gravityG,
    required this.stepMotionCounter,
    required this.stepCadence,
    required this.activityClass,
    required this.tempAux1C,
    required this.tempAux2C,
    required this.skinTempC,
    required this.statusWord,
    required this.statusWord1,
    required this.statusWord2,
    required this.sleepStateByte,
    required this.spo2CandidateRaw,
    required this.opticalBaseline,
    required this.opticalAmp,
    required this.signalQualityLogVariance,
  });

  /// bit7 of [hrQualityFlags] — whether [heartRateAlt] is corroborated this
  /// second.
  bool get hrRrValidThisSecond => (hrQualityFlags & 0x80) != 0;

  /// [heartRateAlt] gated on [hrRrValidThisSecond]; null when unconfirmed.
  ///
  /// Note that "confirmed" still only means 67-75% agreement with
  /// [heartRate] — see [heartRateAlt]. This is a corroboration signal, not a
  /// substitute HR.
  int? get trustedHeartRateAlt => hrRrValidThisSecond ? heartRateAlt : null;

  /// **Do not use.** The byte is zero in 99% of records and nonzero *only*
  /// while [sleepState] is [Gen5SleepState.sleep], so this getter surfaces a
  /// plausible-looking 95-99 on 0.6% of records and null on the rest — with no
  /// validity signal to say which are real. See [spo2CandidateRaw].
  @Deprecated(
    'unsafe to surface: zero in 99% of records, nonzero only during '
    'band-declared sleep, and with no validity flag. Read spo2CandidateRaw '
    'if you need the byte.',
  )
  int? get spo2Candidate => (spo2CandidateRaw >= 70 && spo2CandidateRaw <= 100)
      ? spo2CandidateRaw
      : null;

  /// True when [opticalAmp] reads the 0x8080 sentinel — a signal-quality flag,
  /// not a real amplitude.
  bool get isOpticalAmpSentinel => opticalAmp == 0x8080;

  /// bits 0-1 of [sleepStateByte].
  int get onWristRaw => sleepStateByte & 0x03;

  /// bits 2-3 of [sleepStateByte].
  int get wakeQualityRaw => (sleepStateByte >> 2) & 0x03;

  /// bits 4-5 of [sleepStateByte], raw. Prefer [sleepState].
  int get sleepStateRawNibble => (sleepStateByte >> 4) & 0x03;

  /// bits 6-7 of [sleepStateByte] — a real fourth 2-bit field in this byte,
  /// alongside on-wrist / wake-quality / sleep-state. Exposed raw; no name is
  /// claimed for it because none is established.
  int get bits67Raw => (sleepStateByte >> 6) & 0x03;

  /// The band's own coarse wake/sleep state. Total over the 2-bit nibble, so
  /// never null. **A wake/sleep envelope, not a sleep stage** — see
  /// [Gen5SleepState] for the evidence and the limits.
  Gen5SleepState get sleepState => Gen5SleepState.values[sleepStateRawNibble];
}

/// The EXACT inner length of a v18 record: 112 bytes. Every field this decoder
/// reads fits inside it (the last is
/// [Gen5HistorySample.signalQualityLogVariance], a f32 ending at inner byte
/// 109; the record is padded to a 4-byte boundary). Used as an exact gate, like
/// v20/v21 — a v18 record of any other length is not a v18 record, and
/// accepting one as a floor let short/garbage frames decode into fabricated
/// fields.
const int kGen5V18InnerLen = 112;

@Deprecated('v18 inner is exactly 112 bytes, not a floor — use kGen5V18InnerLen')
const int kGen5V18MinInnerLen = kGen5V18InnerLen;

class Gen5V18Decoder implements Gen5RecordDecoder {
  const Gen5V18Decoder();

  @override
  String get name => 'gen5_v18';

  @override
  bool matches(Uint8List inner) =>
      inner.length == kGen5V18InnerLen && inner[1] == 18;

  @override
  Gen5HistorySample? decode(Uint8List inner) {
    if (!matches(inner)) return null;
    final hdr = Gen5HistoricalHeader.tryParse(inner);
    if (hdr == null) return null;
    final v = _view(inner);

    final hr = inner[14];
    if (hr != 0 && (hr < 25 || hr > 230)) return null; // implausible

    // R-R: up to 4 slots @ inner[16/18/20/22], declared count @ inner[15].
    // Same accept-only-plausible-values discipline as records.dart's R24.
    final declaredRr = inner[15];
    final rr = <int>[];
    if (declaredRr <= 4) {
      for (int i = 0; i < declaredRr && 16 + 2 * i + 2 <= inner.length; i++) {
        final val = v.getInt16(16 + 2 * i, Endian.little);
        if (val >= kMinRrMs && val <= kMaxRrMs) rr.add(val);
      }
    }

    final dynAccel = _round(v.getFloat32(33, Endian.little), 4);
    if (!dynAccel.isFinite || dynAccel < 0 || dynAccel > 8) return null;

    final gx = _round(v.getFloat32(37, Endian.little), 4);
    final gy = _round(v.getFloat32(41, Endian.little), 4);
    final gz = _round(v.getFloat32(45, Endian.little), 4);
    if (!gx.isFinite || !gy.isFinite || !gz.isFinite) return null;
    // These are per-axis means of raw accel, NOT a normalised gravity vector,
    // so a worn strap in motion legitimately exceeds 1.5 g. The old 2.25 ceiling
    // threw away whole records — HR and RR included — for seconds that were only
    // moving. Use the same window gen4 uses (records.dart), and reject only
    // physically impossible vectors.
    final magSq = gx * gx + gy * gy + gz * gz;
    if (magSq < 0.25 || magSq > 3.24) return null; // 0.5g..1.8g

    return Gen5HistorySample(
      histVersion: hdr.version,
      flags: hdr.flags,
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
      tsSubsec: v.getUint16(11, Endian.little),
      heartRate: hr,
      rrCount: rr.length,
      rrIntervalsMs: rr,
      cardiacFlags: inner[25],
      hrQualityFlags: inner[28],
      heartRateAlt: inner[29],
      rrPacked: v.getUint16(30, Endian.little),
      cardiacStatusRaw: inner[32],
      dynamicAccelerationG: dynAccel,
      gravityG: [gx, gy, gz],
      stepMotionCounter: v.getUint16(49, Endian.little),
      stepCadence: inner[51],
      activityClass: inner[55],
      tempAux1C: _round(v.getInt16(61, Endian.little) / 10.0, 2),
      tempAux2C: _round(v.getInt16(63, Endian.little) / 10.0, 2),
      skinTempC: _round(v.getInt16(65, Endian.little) / 100.0, 2),
      statusWord: v.getUint16(67, Endian.little),
      statusWord1: v.getUint16(69, Endian.little),
      statusWord2: v.getUint16(71, Endian.little),
      sleepStateByte: inner[73],
      spo2CandidateRaw: inner[74],
      opticalBaseline: v.getUint16(98, Endian.big),
      opticalAmp: v.getUint16(100, Endian.big),
      signalQualityLogVariance: _round(v.getFloat32(105, Endian.little), 4),
    );
  }
}

// ── v20 — 6-channel raw optical deep buffer (R22 opt-in only). ─────────────

/// One of the 5 fixed 422-byte blocks in a v20 buffer — one AFE channel, its
/// LED drive configuration, and its two photodiode sample slots. See
/// [Gen5OpticalBuffer] for which channel each block index is.
///
/// Per the reference corpus (29,203 records, both sources), only blocks 0/3/4
/// carry samples (`activeSampleCount ∈ {0, 25}`); blocks 1/2 read empty.
///
/// [channel0]/[channel1] are the block's two PHOTODIODES — not two
/// wavelengths. Both slots see the same LED drive; they differ in where on the
/// wrist they sit. The neutral names are kept deliberately.
class Gen5OpticalBlock {
  /// @ block byte 0. Shared by both photodiode slots. 0 or 25 in the reference
  /// corpus; capped to the 50-slot capacity of a 200-byte/4-byte-sample slot.
  final int activeSampleCount;

  /// Raw sign-extended 20-bit samples (returned as ints in [-524288, 524287]),
  /// length == [activeSampleCount].
  final List<int> channel0;
  final List<int> channel1;

  /// bytes[1:7] of the block — the LED drive configuration, decomposed by
  /// [ledADriverConnection] / [ledACurrentRaw] / [ledBDriverConnection] /
  /// [ledBCurrentRaw]. Kept raw as well, for re-derivation.
  final Uint8List sharedMetaRaw;

  /// bytes[7:14] — photodiode 0's front-end configuration:
  /// {source byte, u32 ADC range, u16 ADC offset}. See [channel0Source],
  /// [channel0AdcRange], [channel0AdcOffset].
  final Uint8List channel0MetaRaw;

  /// bytes[14:21] — photodiode 1's, same three fields.
  final Uint8List channel1MetaRaw;

  const Gen5OpticalBlock({
    required this.activeSampleCount,
    required this.channel0,
    required this.channel1,
    required this.sharedMetaRaw,
    required this.channel0MetaRaw,
    required this.channel1MetaRaw,
  });

  /// Which driver output LED A is wired to for this block. @ sharedMeta[0].
  int get ledADriverConnection => sharedMetaRaw[0];

  /// LED A drive current in units of 10 µA. @ sharedMeta[1:3] u16.
  /// [ledACurrentMicroamps] is the same number in µA.
  int get ledACurrentRaw => _u16(sharedMetaRaw, 1);
  int get ledACurrentMicroamps => ledACurrentRaw * 10;

  /// Which driver output LED B is wired to. @ sharedMeta[3].
  int get ledBDriverConnection => sharedMetaRaw[3];

  /// LED B drive current in units of 10 µA. @ sharedMeta[4:6] u16.
  int get ledBCurrentRaw => _u16(sharedMetaRaw, 4);
  int get ledBCurrentMicroamps => ledBCurrentRaw * 10;

  /// Photodiode 0's input source selector. @ channel0Meta[0].
  int get channel0Source => channel0MetaRaw[0];

  /// Photodiode 0's ADC full-scale range. @ channel0Meta[1:5] u32.
  int get channel0AdcRange => _u32(channel0MetaRaw, 1);

  /// Photodiode 0's ADC offset. @ channel0Meta[5:7] u16.
  int get channel0AdcOffset => _u16(channel0MetaRaw, 5);

  /// Photodiode 1's, same three fields at the same offsets.
  int get channel1Source => channel1MetaRaw[0];
  int get channel1AdcRange => _u32(channel1MetaRaw, 1);
  int get channel1AdcOffset => _u16(channel1MetaRaw, 5);
}

int _u16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
int _u32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// The raw optical deep buffer. Layout is confirmed: the body starts at inner
/// 18, then 5 blocks of 422 bytes each; every block holds 50 sample-pair slots,
/// photodiode slot A at `block + 21` and slot B at `block + 221`, and the
/// samples are sign-extended 20-bit values (see [_signExtend20]). Total inner
/// length is therefore exactly 2128 ([kGen5V20InnerLen]).
///
/// The 5 blocks are the AFE's channels, in index order:
///
/// | block | channel |
/// |-------|---------|
/// | 0 | green — the primary HR channel |
/// | 1 | red |
/// | 2 | a fourth channel |
/// | 3 | IR |
/// | 4 | ambient (no LED — the dark/background reference) |
///
/// Block 3 falls back to another channel's source when the primary IR emitter
/// is disabled; bit 0 of [flags] is what signals that fallback, so check it
/// before assuming block 3 is IR.
///
/// **Amplitudes are not comparable across records without the block
/// metadata.** Each block carries its own LED drive current and per-photodiode
/// ADC range/offset ([Gen5OpticalBlock.ledACurrentMicroamps],
/// [Gen5OpticalBlock.channel0AdcRange], ...), and the band re-tunes them
/// continuously. Two records whose raw counts differ may be the same optical
/// signal at a different gain; normalise by current and range before comparing
/// or trending.
class Gen5OpticalBuffer extends Gen5HistoricalRecord {
  /// Sample rate of this buffer in Hz, u16 LE @ inner[15:17] — v20 states its
  /// own rate rather than leaving it to be inferred from the sample count.
  final int sampleRateHz;

  /// Always 5 entries (blocks 0-4), even the empty 1/2 slots — index == block
  /// number == channel per the table above, matching the reference corpus's
  /// `sampleCount` array convention (`[25, 0, 0, 25, 25]`).
  final List<Gen5OpticalBlock> blocks;

  const Gen5OpticalBuffer({
    required super.histVersion,
    required super.flags,
    required super.recordIndex,
    required super.unix,
    required super.tsSubsec,
    required this.sampleRateHz,
    required this.blocks,
  });
}

/// Byte offset (inner-relative) where the 5×422-byte block body starts.
/// Frame-absolute 26 → inner 18 (26 - 8).
const int _kV20BodyStart = 18;
const int _kV20BlockLen = 422;
const int _kV20NumBlocks = 5;

/// The exact inner length of a v20 buffer: total on-wire frame is 2140 bytes
/// (8-byte header + padded-inner + 4-byte CRC32) per the reference fixture,
/// so padded-inner = 2140 - 8 - 4 = 2128. Used as v20's PRIMARY identity
/// check — length-gated before the version byte is even trusted, mirroring
/// both reference repos' defensive pattern (§1.5).
const int kGen5V20InnerLen =
    _kV20BodyStart + _kV20NumBlocks * _kV20BlockLen; // 2128

int _signExtend20(int raw20) {
  final masked = raw20 & 0xFFFFF;
  return (masked & 0x80000) != 0 ? masked - 0x100000 : masked;
}

Gen5OpticalBlock _decodeOpticalBlock(Uint8List inner, int blockStart) {
  final v = _view(inner);
  final rawCount = inner[blockStart];
  final activeSampleCount = rawCount > 50 ? 0 : rawCount; // capacity guard
  final ch0Start = blockStart + 21;
  final ch1Start = ch0Start + 200;

  List<int> readChannel(int start) {
    final out = <int>[];
    for (int i = 0; i < activeSampleCount; i++) {
      final off = start + 4 * i;
      if (off + 4 > inner.length) break;
      out.add(_signExtend20(v.getUint32(off, Endian.little)));
    }
    return out;
  }

  return Gen5OpticalBlock(
    activeSampleCount: activeSampleCount,
    channel0: readChannel(ch0Start),
    channel1: readChannel(ch1Start),
    sharedMetaRaw:
        Uint8List.fromList(inner.sublist(blockStart + 1, blockStart + 7)),
    channel0MetaRaw:
        Uint8List.fromList(inner.sublist(blockStart + 7, blockStart + 14)),
    channel1MetaRaw:
        Uint8List.fromList(inner.sublist(blockStart + 14, blockStart + 21)),
  );
}

class Gen5V20Decoder implements Gen5RecordDecoder {
  const Gen5V20Decoder();

  @override
  String get name => 'gen5_v20';

  @override
  bool matches(Uint8List inner) =>
      inner.length == kGen5V20InnerLen && inner[1] == 20;

  @override
  Gen5OpticalBuffer? decode(Uint8List inner) {
    if (!matches(inner)) return null;
    final hdr = Gen5HistoricalHeader.tryParse(inner);
    if (hdr == null) return null;

    final blocks = <Gen5OpticalBlock>[];
    for (int b = 0; b < _kV20NumBlocks; b++) {
      final start = _kV20BodyStart + b * _kV20BlockLen;
      blocks.add(_decodeOpticalBlock(inner, start));
    }

    final v = _view(inner);
    return Gen5OpticalBuffer(
      histVersion: hdr.version,
      flags: hdr.flags,
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
      tsSubsec: v.getUint16(11, Endian.little),
      sampleRateHz: v.getUint16(15, Endian.little),
      blocks: blocks,
    );
  }
}

// ── v21 — 100Hz 6-axis raw IMU buffer (R22 opt-in only). ───────────────────

/// Decoded gen5 v21 IMU buffer. High-confidence layout — exact 3-way
/// agreement between whoop-rs, noop, and this file's own byte-level
/// verification (§1.5). The 100 Hz sample rate is confirmed: the band
/// configures both blocks at 100 Hz, so a full block is one second of motion.
class Gen5ImuBuffer extends Gen5HistoricalRecord {
  /// Samples actually present in each block: [countA] for the accel axes,
  /// [countB] for the gyro axes. 1..100 — a block declares how much of its
  /// fixed 100-sample capacity it filled, and a partly-filled buffer is still
  /// a genuine buffer. Part of [isGen5ImuBuffer]'s gate, since this record
  /// kind is identified by shape rather than `hist_version`.
  final int countA;
  final int countB;

  /// g, scale [kGen5AccelScaleG]. [countA] samples each, NOT always 100.
  final List<double> accelXg;
  final List<double> accelYg;
  final List<double> accelZg;

  /// deg/s, scale [kGen5GyroScaleDps] (±2000 dps full-scale). [countB] samples
  /// each, NOT always 100.
  final List<double> gyroXdps;
  final List<double> gyroYdps;
  final List<double> gyroZdps;

  const Gen5ImuBuffer({
    required super.histVersion,
    required super.flags,
    required super.recordIndex,
    required super.unix,
    required super.tsSubsec,
    required this.countA,
    required this.countB,
    required this.accelXg,
    required this.accelYg,
    required this.accelZg,
    required this.gyroXdps,
    required this.gyroYdps,
    required this.gyroZdps,
  });
}

// Gyro full-scale ±2000dps over signed int16 → 2000/32768 deg/s per LSB.
// Identical constant to live.dart's `_gyroScale` (R10 IMU) — the scale is
// shared across every WHOOP gyro stream this package decodes.
const double kGen5GyroScaleDps = 2000.0 / 32768.0;
const double kGen5AccelScaleG = 1.0 / 4096.0;

// Each of the two sample blocks is prefixed by
//   [u16 capacity][u16 count][u8 sensor id][u8 flags]
// so the *count* is the second word, not the first. Sensor id 3 = accel
// (first block), 5 = gyro (second). Capacity is a fixed 100 and carries no
// information — gating on it can never fail.
const int _kV21CountAOffset = 16; // frame-abs 24
const int _kV21AxStart = 20; // frame-abs 28
const int _kV21CountBOffset = 622; // frame-abs 630
const int _kV21GxStart = 632; // frame-abs 640
const int _kV21SamplesPerAxis = 100;

/// Exact inner length: total on-wire frame is 1244 bytes, so padded-inner =
/// 1244 - 8 - 4 = 1232. PRIMARY identity check, along with [Gen5V21Decoder]'s
/// bounded-count gate — neither the length nor the counts depend on trusting
/// `hist_version` at all, matching how both reference repos actually
/// identify this buffer.
const int kGen5V21InnerLen = _kV21GxStart + 3 * 2 * _kV21SamplesPerAxis; // 1232

/// True when [inner] carries a record-21 IMU buffer, whichever packet type it
/// arrived under. The shape check is independent of `hist_version`.
bool isGen5ImuBuffer(Uint8List inner) {
  if (inner.length != kGen5V21InnerLen) return false;
  final v = _view(inner);
  final countA = v.getUint16(_kV21CountAOffset, Endian.little);
  final countB = v.getUint16(_kV21CountBOffset, Endian.little);
  // A partly-filled buffer is still a valid buffer — it just carries fewer than
  // the block's capacity. Requiring exactly the capacity rejected every short
  // buffer outright.
  return countA >= 1 &&
      countA <= _kV21SamplesPerAxis &&
      countB >= 1 &&
      countB <= _kV21SamplesPerAxis;
}

/// Decode a record-21 IMU buffer.
///
/// The same buffer reaches us two ways: as a historical record (packet type
/// 0x2F) and as a live realtime frame (0x2B). Identical header, offsets and
/// scales in both cases, so both go through here rather than through two
/// decoders that can drift apart.
Gen5ImuBuffer? parseGen5ImuBuffer(Uint8List inner) {
  if (!isGen5ImuBuffer(inner)) return null;
  final hdr = Gen5HistoricalHeader.tryParse(inner);
  if (hdr == null) return null;
  final v = _view(inner);

  final countA = v.getUint16(_kV21CountAOffset, Endian.little);
  final countB = v.getUint16(_kV21CountBOffset, Endian.little);

  // Read only the samples the block declares. Decoding the full capacity from
  // a partly-filled buffer emits whatever stale bytes follow the valid ones as
  // if they were real motion.
  List<double> axis(int start, double scale, int count) {
    final out = <double>[];
    for (int i = 0; i < count; i++) {
      out.add(v.getInt16(start + 2 * i, Endian.little) * scale);
    }
    return out;
  }

  return Gen5ImuBuffer(
    histVersion: hdr.version,
    flags: hdr.flags,
    recordIndex: hdr.recordIndex,
    unix: hdr.unix,
    tsSubsec: v.getUint16(11, Endian.little),
    countA: countA,
    countB: countB,
    accelXg: axis(_kV21AxStart, kGen5AccelScaleG, countA),
    accelYg: axis(_kV21AxStart + 200, kGen5AccelScaleG, countA),
    accelZg: axis(_kV21AxStart + 400, kGen5AccelScaleG, countA),
    gyroXdps: axis(_kV21GxStart, kGen5GyroScaleDps, countB),
    gyroYdps: axis(_kV21GxStart + 200, kGen5GyroScaleDps, countB),
    gyroZdps: axis(_kV21GxStart + 400, kGen5GyroScaleDps, countB),
  );
}

class Gen5V21Decoder implements Gen5RecordDecoder {
  const Gen5V21Decoder();

  @override
  String get name => 'gen5_v21';

  @override
  bool matches(Uint8List inner) => isGen5ImuBuffer(inner);

  @override
  Gen5ImuBuffer? decode(Uint8List inner) => parseGen5ImuBuffer(inner);
}

// ── v26 — single-wavelength PPG waveform, 24 SAMPLES per record. ───────────
//
// 24 is a sample COUNT, not a rate: nothing here runs at "24 Hz". The samples
// were taken at the optical front end's configured rate, which the record
// states itself via bit 7 of its flags byte — see
// [Gen5HistoricalRecord.ppgSampleRateHz] (25 or 50 Hz).

class Gen5PpgWaveform extends Gen5HistoricalRecord {
  /// Low byte of the record's sub-second @ inner[11] (frame-abs 19).
  ///
  /// This offset is the shared u16 sub-second, not a byte: reading one byte
  /// here discards its high half (nonzero on 99% of real records).
  @Deprecated('frame-abs 19 is the u16 sub-second — use tsSubsec / subSecond')
  final int rawByte19;

  /// u16 LE @ inner[11:13] (frame-abs 19) — the SAME field as [tsSubsec], the
  /// record's Q15 sub-second, kept under its historical name.
  ///
  /// It reads constant across the records of one burst because a burst shares
  /// one timestamp. The value is an integer `k` in 0..99 packed as a Q15
  /// fraction (`segmentId == (k * 32768) ~/ 100` for every record observed):
  /// `k` is the sub-second in hundredths, i.e. [subSecond] × 100. See
  /// [segmentIndex].
  final int segmentId;

  /// Per-burst counter (NOT a channel/LED id — ranges past 26 in the
  /// reference corpus). @ inner[13] (frame-abs 21).
  final int burstIndex;

  /// u16 LE @ inner[15:17] (frame-abs 23). No meaning established — it does
  /// not track heart rate, motion, the waveform, gain or [signalMetric].
  /// Exposed raw, don't consume.
  final int frontEndMetaRaw;

  /// Acquisition-channel index @ inner[17] (frame-abs 25), 0..7.
  ///
  /// **The band multiplexes several optical channels through one v26 stream**,
  /// and this byte is what separates them. Consecutive records in a single
  /// burst carry different values, each with its own gain configuration
  /// ([gainIndex]/[gainSetting]) and its own amplitude, and each carries an
  /// independent pulse. Without splitting on it, a burst is several channels
  /// interleaved, which is not a signal.
  ///
  /// Values outside 0..7 occur on about 0.2% of records (0xFD..0xFF). They are
  /// not obviously invalid — the waveform still looks like a pulse — but they
  /// are not a channel index either, so use [subChannelKnown].
  final int subChannel;

  /// [subChannel] gated to the 0..7 range, null otherwise — the honest getter,
  /// mirroring [Gen5HistorySample.activityClassKnown].
  int? get subChannelKnown =>
      (subChannel >= 0 && subChannel <= 7) ? subChannel : null;

  /// `k` in 0..99 recovered from [segmentId]'s Q15 packing — the sub-second in
  /// hundredths — or null if this record's value doesn't fit the packing.
  int? get segmentIndex {
    final k = ((segmentId * 100) / 32768).round();
    return (k >= 0 && k <= 99 && (k * 32768) ~/ 100 == segmentId) ? k : null;
  }

  /// f32 LE @ inner[67:71] (frame-abs 75). Tracks with [flagA]/[flagB] as a
  /// per-record signal-quality indicator where LOW means a clean record, but
  /// the scale is unpinned. Exposed raw.
  final double signalMetric;

  /// Front-end gain configuration @ inner[71] / inner[72] (frame-abs 79/80).
  /// Each [subChannel] runs a characteristic gain, adjusted within a range.
  final int gainSetting;
  final int gainIndex;

  /// Raw flag bytes @ inner[73] / inner[74] (frame-abs 81/82). Roughly
  /// complementary, and [signalMetric] is about an order of magnitude lower
  /// when [flagB] is set. Meaning otherwise unestablished — exposed raw.
  final int flagA;
  final int flagB;

  /// Raw AC-coupled ADC samples, no physical unit. Always 24 of them — the
  /// record's fixed size. Every channel is DC-removed on the band: the
  /// per-record sample mean is ~0 for all values of [subChannel].
  final List<int> ppgWaveform;

  const Gen5PpgWaveform({
    required super.histVersion,
    required super.flags,
    required super.recordIndex,
    required super.unix,
    required super.tsSubsec,
    @Deprecated('frame-abs 19 is the u16 sub-second — use tsSubsec / subSecond')
    required this.rawByte19,
    required this.segmentId,
    required this.burstIndex,
    required this.frontEndMetaRaw,
    required this.subChannel,
    required this.signalMetric,
    required this.gainSetting,
    required this.gainIndex,
    required this.flagA,
    required this.flagB,
    required this.ppgWaveform,
  });
}

const int _kV26SampleCount = 24;
const int _kV26SamplesStart = 19; // frame-abs 27

/// The EXACT inner length of a v26 record: 76 bytes — 24 samples at
/// inner[19:67] plus the trailing metadata block ending at inner[74], padded
/// to a 4-byte boundary. An exact gate, like v20/v21: a truncated record's
/// trailing metadata would otherwise decode out of whatever bytes happened to
/// follow.
const int kGen5V26InnerLen = 76;

@Deprecated('v26 inner is exactly 76 bytes, not a floor — use kGen5V26InnerLen')
const int kGen5V26MinInnerLen = kGen5V26InnerLen;

@Deprecated('v26 inner is exactly 76 bytes, not a floor — use kGen5V26InnerLen')
const int kGen5V26MinInnerLenWithMeta = kGen5V26InnerLen;

class Gen5V26Decoder implements Gen5RecordDecoder {
  const Gen5V26Decoder();

  @override
  String get name => 'gen5_v26';

  @override
  bool matches(Uint8List inner) =>
      inner.length == kGen5V26InnerLen && inner[1] == 26;

  @override
  Gen5PpgWaveform? decode(Uint8List inner) {
    if (!matches(inner)) return null;
    final hdr = Gen5HistoricalHeader.tryParse(inner);
    if (hdr == null) return null;
    final v = _view(inner);

    final samples = <int>[];
    for (int i = 0; i < _kV26SampleCount; i++) {
      samples.add(v.getInt16(_kV26SamplesStart + 2 * i, Endian.little));
    }

    return Gen5PpgWaveform(
      histVersion: hdr.version,
      // v26 uses the SAME u32 record_index as every other version. The u16 read
      // that used to live here truncated it: the counter is continuous with
      // v18's (a v18/v26 pair one second apart differs by exactly 1 in both the
      // counter and unix), and inner[5:7] is its high half — constant within a
      // capture, not a separate field. Truncating wrapped it every ~18h and made
      // it non-monotonic.
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
      tsSubsec: v.getUint16(11, Endian.little),
      flags: hdr.flags,
      // ignore: deprecated_member_use_from_same_package
      rawByte19: inner[11],
      segmentId: v.getUint16(11, Endian.little),
      burstIndex: inner[13],
      frontEndMetaRaw: v.getUint16(15, Endian.little),
      subChannel: inner[17],
      signalMetric: v.getFloat32(67, Endian.little),
      gainSetting: inner[71],
      gainIndex: inner[72],
      flagA: inner[73],
      flagB: inner[74],
      ppgWaveform: samples,
    );
  }
}

// ── RecordDecoder interface + dispatch (§4's "Layer 2" recommendation). ────
//
// Each decoder does its own cheap pre-check (`matches`) BEFORE trusting
// `hist_version` — v21 in particular is identified purely by shape (paired
// sample counts), matching how both reference repos actually recognise it.
// Adding a future band's record kind means writing one more of these and
// registering it in [kGen5HistoricalDecoders]; nothing here needs to branch
// on a generation name.
abstract class Gen5RecordDecoder {
  String get name;
  bool matches(Uint8List inner);
  Gen5HistoricalRecord? decode(Uint8List inner);
}

const Gen5V18Decoder _v18Decoder = Gen5V18Decoder();
const Gen5V20Decoder _v20Decoder = Gen5V20Decoder();
const Gen5V21Decoder _v21Decoder = Gen5V21Decoder();
const Gen5V26Decoder _v26Decoder = Gen5V26Decoder();

/// Every gen5 historical-record decoder this package knows, in dispatch
/// order. v21 is checked FIRST (see [parseGen5Historical]) because it cannot
/// be trusted via `hist_version` at all; the others dispatch off the version
/// byte for speed once v21 is ruled out.
const List<Gen5RecordDecoder> kGen5HistoricalDecoders = [
  _v21Decoder,
  _v18Decoder,
  _v20Decoder,
  _v26Decoder,
];

/// Decode a gen5 historical record (`inner` starts at the packet-type byte
/// `0x2F`, exactly like [parseGen5Historical]'s gen4 sibling `parseR24`).
///
/// Dispatch: v21 is tried FIRST via its own shape gate (paired 100-sample
/// counts) since it "has no confirmed place in the version-byte scheme"
/// (§1.5) — an exact-length v21 buffer whose counts both read 100 could in
/// principle collide with a mis-length-matching v18/v20/v26 record, but the
/// exact-length gate (1232 bytes) makes that practically impossible given
/// v18's much shorter length and v20's different exact length (2128).
/// Everything else dispatches off `inner[1]` (hist_version).
///
/// Returns null for anything this package doesn't have a decoder for (e.g. an
/// unrecognised version, or a too-short/garbage frame) — the caller archives
/// those, exactly like `parseR24`'s null contract.
Gen5HistoricalRecord? parseGen5Historical(Uint8List inner) {
  if (inner.length < 11) return null; // shorter than the shared header itself

  if (_v21Decoder.matches(inner)) return _v21Decoder.decode(inner);

  switch (inner[1]) {
    case 18:
      return _v18Decoder.decode(inner);
    case 20:
      return _v20Decoder.decode(inner);
    case 26:
      return _v26Decoder.decode(inner);
    default:
      return null;
  }
}
