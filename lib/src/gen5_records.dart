// gen5_records.dart — WHOOP 5 (gen5 / "fd4b" / "Maverick-Goose") historical
// record decoders: v18 (per-second biometric summary), v20 (raw optical deep
// buffer, 5 AFE channels × 2 photodiodes), v21 (100Hz 6-axis IMU deep buffer),
// v26 (the Pulse Information Packet — a copied 72-byte PIP ring record holding
// a 25-sample optical window encoded as one absolute first sample plus 24
// SATURATED DELTAS; 24/25 are sample counts, not rates — the rate is whatever
// PPG rate the record's own flags byte declares, see
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
// gen5_historical_test.dart for the golden parity tests. v26's trailing
// metadata block was additionally re-derived (see the v26 section below)
// after an earlier reading of it turned out to be wrong.
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
double? _finiteOrNull(double v) => v.isFinite ? v : null;

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
  /// bpm. 0 is the band's own "no reading this second" (warming up / off skin),
  /// and it is also what we emit when the HR byte lands outside 25..230 — an
  /// out-of-range byte is not a heart rate, and the rest of the record still
  /// decodes. Never a clamped or carried-forward number.
  final int heartRate;

  /// Number of R-R intervals we ACCEPTED (see [rrIntervalsMs] doc) — always
  /// `rrIntervalsMs.length`, never the raw declared count byte, mirroring
  /// records.dart's R24 convention.
  final int rrCount;
  final List<int> rrIntervalsMs;

  /// Raw @ inner[25] (frame-abs 33). whoop-rs calls this offset
  /// "signal_flags"; the meaning is otherwise unconfirmed. Exposed raw.
  final int cardiacFlags;

  /// @ inner[28] (frame-abs 36) — a flags-plus-counter byte.
  ///
  /// **bit7 is NOT an "HR valid this second" flag.** Records routinely carry a
  /// valid HR (25..230) with bit7 CLEAR, and the bit toggles roughly 50/50
  /// independent of HR presence, so it cannot gate HR validity. No discrete
  /// per-second HR-valid field exists anywhere in v18: HR PRESENCE is
  /// `heartRate` in range, and HR QUALITY is [signalQualityLogVariance].
  /// bit7 does track agreement between [heartRate] and [heartRateAlt] — see
  /// [hrRrValidThisSecond].
  ///
  /// Other bits: 0x10 = source-2 (CH3 infrared) selected, 0x20 =
  /// transition/hold, 0x40 = a mirror bit. The low 4 bits are a separate small
  /// field, uniform over 0..15 — see [hrQualityCounter].
  final int hrQualityFlags;

  /// Low 4 bits of [hrQualityFlags] — a small field, uniform over 0..15,
  /// independent of bit7. Purpose unknown; exposed for diagnostics only.
  int get hrQualityCounter => hrQualityFlags & 0x0F;

  /// bit `0x10` of [hrQualityFlags]: the signal processor selected source
  /// index 2 — **CH3 infrared** — as the HR source this second.
  ///
  /// Never observed set in resting/sleep records, which is consistent with
  /// green staying selected — so treat "false" as "green, or not exercised",
  /// not as proof the band cannot switch.
  bool get irSourceSelected => (hrQualityFlags & 0x10) != 0;

  /// Second heart-rate-like byte @ inner[29] (frame-abs 37).
  ///
  /// Exposed raw and UNCLAIMED: it usually tracks [heartRate] closely, with
  /// occasional near-misses of a few bpm and occasional zeros while
  /// [heartRate] is present (one estimator abstaining), but its exact
  /// semantics are not pinned. Do not substitute it for [heartRate] or consume
  /// it as a decoded metric — see [trustedHeartRateAlt] for the gated read.
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

  /// Maximum adjacent acceleration-vector-magnitude delta (g) @ inner[33:37]
  /// f32 LE (frame-abs 41), computed on-band from the same 100 raw accel
  /// samples as R21. NOT a gravity-removed magnitude — it is the max adjacent
  /// delta, and R26 carries the identical f32 (byte-equal on paired records).
  /// NULL when the bytes are not a finite in-full-scale value — absent,
  /// not zero. The rest of the record is still valid (see [Gen5V18Decoder]).
  final double? dynamicAccelerationG;

  /// [x, y, z] (g) @ inner[37/41/45] f32 LE each (frame-abs 45/49/53), or
  /// EMPTY when absent. These are per-axis means of raw accel, NOT a
  /// normalised gravity vector, so a worn strap in motion legitimately reads
  /// well above 1 g: do not gate this field on gen4's gravity-magnitude
  /// window, or on any bound derived from the other generation. The decoder
  /// checks only finiteness and the part's ±16 g full scale.
  final List<double> gravityG;

  /// Cumulative on-chip step counter @ inner[49:51] u16 LE (frame-abs 57).
  /// FULL 2 bytes — an earlier bug (fixed upstream, noop #132/#276) read
  /// only the low byte. No midnight reset.
  ///
  /// Passive behaviour supports a counter, but the NAME is not established:
  /// the byte pair is near-monotonically non-decreasing across long runs of
  /// records, i.e. it behaves like a wrapping counter rather than a static
  /// config value. That is behaviour, not semantics — nothing yet ties these
  /// bytes to steps as their producer. Two independent third-party clients
  /// read it as an on-chip step counter, which is why this field keeps that
  /// name; treat it as their inference until the producer is pinned.
  final int stepMotionCounter;

  /// Raw @ inner[51] u8 (frame-abs 59). inner[52] is a hard zero, so a u16 read
  /// here happens to give the same number — but the field is one byte.
  ///
  /// NAME CAVEAT, same as [stepMotionCounter]: only the behaviour is pinned
  /// (smooth over 51..254); the "cadence" label is the reference clients'
  /// inference, kept for compatibility until the producer is pinned.
  final int stepCadence;

  /// RAW byte @ inner[55] (frame-abs 63). NAME CAVEAT, same as
  /// [stepMotionCounter]: only the behaviour ({0,1,2}) is pinned; the
  /// walk/run reading below is the reference clients' inference.
  /// Only 0 / 1 (walk) / 2 (run) are
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

  /// Fuel-gauge CELL temperature, °C = raw/10. @ inner[61:63] i16 LE
  /// (frame-abs 69).
  final double tempAux1C;

  /// Fuel-gauge AMBIENT temperature, °C = raw/10. @ inner[63:65] i16 LE
  /// (frame-abs 71).
  final double tempAux2C;

  /// AS6221 SKIN temperature, °C = raw/100 — a GEN5-SPECIFIC scale; do NOT
  /// reuse gen4's per-device affine scale here. @ inner[65:67] **i16** LE
  /// (frame-abs 73). Signed: an unsigned read turns anything below 0 °C into
  /// ≈ +655 °C. Confirmed worn≈30.6°C / off-wrist≈22.5°C on real captures.
  ///
  /// The raw sentinel **-5000 (= -50.00 °C) means unavailable/error** — use
  /// [skinTempAvailable] before showing this as a temperature, or
  /// [skinTempCOrNull] to abstain honestly.
  final double skinTempC;

  /// False when [skinTempC] is the -50.00 °C unavailable/error sentinel.
  bool get skinTempAvailable => (skinTempC * 100).round() != -5000;

  /// [skinTempC] or null when the reading is the unavailable sentinel — the
  /// honest accessor (never surface -50 °C as a real skin temperature).
  double? get skinTempCOrNull => skinTempAvailable ? skinTempC : null;

  /// The three packed per-channel AGC/state words @ inner[67/69/71] u16 LE
  /// (frame-abs 75/77/79). NOT deep-sleep markers (the noop reading).
  /// Bit layout:
  ///   bits 0-1   channel index      bits 2-3   zero
  ///   bits 4-7   PD-A/PD-B AGC offset-current indices
  ///   bits 8-11  LED-current index
  ///   bits 12-15 saturation-majority flags — set when more than 20 of the 25
  ///              processed samples saturated high/low for PD A/B
  /// An INACTIVE channel reads `0x0c00 | channel_index`. The saturation bits
  /// are the useful ones for a consumer: a second whose optical channel
  /// saturated is not a trustworthy optical second.
  final int statusWord;
  final int statusWord1;
  final int statusWord2;

  /// True when any of the three channel words reports a saturation majority
  /// (bits 12-15) — i.e. this second's optical signal was rail-pinned on at
  /// least one detector. A quality gate, not a measurement.
  bool get opticalSaturated =>
      ((statusWord | statusWord1 | statusWord2) & 0xF000) != 0;

  /// Raw @ inner[73] (frame-abs 81). Packed 2-bit slots:
  ///   bits 0-1: **primary-flags bit-8 snapshot** — NOT a wear indicator. (The
  ///     same source appears at R26 body 60; the two records mirror it.)
  ///   bits 2-3: **passive strap-fit classifier state** (the feature behind
  ///     `enable_passive_strap_fit_gen5`) — not a "wake quality".
  ///   bits 4-5: sleep_state — 0 wake / 1 still / 2 sleep / 3 up. Prefer
  ///     [sleepState] over reading the nibble yourself. whoop-rs's
  ///     "0 still / 1 wake" is the wrong way round.
  ///   bits 6-7: documented as the **high slot, zero**. Exposed raw so a
  ///     nonzero value is visible if firmware ever uses it — see [bits67Raw].
  final int sleepStateByte;

  /// @ inner[74] (frame-abs 82) — the **SpO2 estimate/status byte**. The
  /// family is established; the ENCODING is not (not every nonzero encoding
  /// is a percentage), so this stays a raw byte and the package refuses to
  /// publish a percentage from it.
  ///
  /// It reads 0 in the vast majority of records and is *identically* zero
  /// unless [sleepState] is [Gen5SleepState.sleep], where it fires on a small
  /// fraction of records clustering at 95-99 — consistent with a scheduled
  /// overnight sampling cadence, and with the R22 tag-3 pairing where every
  /// nonzero-SpO2 second coincides with a populated CH2/CH4 window. Values
  /// above 128 decompose as `128 + <a value from the low set>`, so bit 7
  /// looks like a flag rather than part of the number.
  ///
  /// Surfacing a user-facing SpO2 needs the encoding pinned first.
  final int spo2CandidateRaw;

  /// `inner[98]`/`inner[99]` (u8 each): two quantized selected-source
  /// photodiode MEAN diagnostics (PD-B then PD-A, in that order). NOT one
  /// big-endian u16 — the band writes these as independent bytes with an
  /// exact per-detector transform but no established physical unit.
  final int pdMeanB;
  final int pdMeanA;

  /// `inner[100]`/`inner[101]`: two SIGNED int8 per-detector pSNR values in
  /// dB for the currently selected HR source (PD-B then PD-A).
  /// **-128 (`0x80`) means unavailable** — do not read it as −128 dB. This is
  /// why reading [100:102] as one big-endian u16 produced the spurious `0x8080`
  /// "sentinel": it was simply both detectors reporting unavailable at once.
  /// The two move as a pair (never observed unavailable alone), which is why
  /// the paired 0x8080 value looked like a single sentinel.
  final int psnrB;
  final int psnrA;

  /// Whether the pSNR value for that detector is a real reading (not the -128
  /// unavailable sentinel).
  bool get psnrBAvailable => psnrB != -128;
  bool get psnrAAvailable => psnrA != -128;

  /// COMPAT (deprecated): the old big-endian-u16 reads of these byte pairs.
  /// Both conflated two independent fields; kept only so existing callers still
  /// compile. `opticalBaseline` was `(pdMeanB<<8)|pdMeanA` and `opticalAmp` the
  /// raw `(psnrB<<8)|psnrA` — the latter is the `0x8080` both-unavailable case.
  @Deprecated('two independent u8 PD means, not a u16 — use pdMeanB/pdMeanA')
  int get opticalBaseline => (pdMeanB << 8) | pdMeanA;
  @Deprecated('two independent i8 pSNR values, not a u16 — use psnrB/psnrA')
  int get opticalAmp => ((psnrB & 0xFF) << 8) | (psnrA & 0xFF);

  /// @ inner[105:109] f32 LE (frame-abs 113). A per-second signal-quality
  /// metric the band's own optical processing computes: the log-variance of
  /// the signal it measured this second. Range ~-5.3..0 on the reference
  /// corpus — lower is a quieter, cleaner signal.
  ///
  /// Usable as a quality weight (e.g. to down-weight a second's HR/RR), which
  /// is what it is for. The absolute scale is the band's, not a physical unit,
  /// so compare it against other seconds, not against a threshold you invent.
  ///
  /// Null when those bytes are not finite — they are then not this f32, and a
  /// NaN weight silently poisons every comparison and mean it touches.
  final double? signalQualityLogVariance;

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
    required this.pdMeanB,
    required this.pdMeanA,
    required this.psnrB,
    required this.psnrA,
    required this.signalQualityLogVariance,
  });

  /// bit7 of [hrQualityFlags] — whether [heartRateAlt] is corroborated this
  /// second.
  ///
  /// NOT an "HR valid" bit ([heartRate] is routinely present and in range
  /// while this bit is clear — see [hrQualityFlags]). Gate nothing on it
  /// except [trustedHeartRateAlt].
  bool get hrRrValidThisSecond => (hrQualityFlags & 0x80) != 0;

  /// [heartRateAlt] gated on [hrRrValidThisSecond]; null when unconfirmed.
  ///
  /// "Confirmed" is a corroboration signal between the record's two
  /// heart-rate bytes, not a substitute HR — read [heartRate] for the value.
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

  /// True when BOTH per-detector pSNR values read the -128 unavailable
  /// sentinel — i.e. the old `opticalAmp == 0x8080` case, which was never a
  /// real amplitude, just both detectors reporting unavailable at once.
  bool get isOpticalAmpSentinel => !psnrBAvailable && !psnrAAvailable;

  /// bits 0-1 of [sleepStateByte] — the primary-flags bit-8 snapshot.
  int get primaryFlagsBit8Raw => sleepStateByte & 0x03;

  /// bits 2-3 of [sleepStateByte] — the passive strap-fit classifier state.
  int get strapFitStateRaw => (sleepStateByte >> 2) & 0x03;

  /// **Deprecated: not a wear indicator.** Bits 0-1 are the primary-flags
  /// bit-8 snapshot; nothing supports reading
  /// them as on-wrist. Wear state comes from the HELLO body, the wrist
  /// on/off events, or the fact that the band stops emitting type-40 off-wrist.
  @Deprecated('bits 0-1 are the primary-flags bit-8 snapshot, not wear state — '
      'use primaryFlagsBit8Raw (and do not treat it as on-wrist)')
  int get onWristRaw => primaryFlagsBit8Raw;

  /// **Deprecated: misnamed.** These bits are the passive strap-fit classifier
  /// state, not a wake-quality score.
  @Deprecated('bits 2-3 are the passive strap-fit classifier state — '
      'use strapFitStateRaw')
  int get wakeQualityRaw => strapFitStateRaw;

  /// bits 4-5 of [sleepStateByte], raw. Prefer [sleepState].
  int get sleepStateRawNibble => (sleepStateByte >> 4) & 0x03;

  /// bits 6-7 of [sleepStateByte] — a high slot that always reads ZERO on
  /// current firmware. Exposed raw rather than assumed away,
  /// so a nonzero value on some future firmware is visible instead of silent.
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

/// Shortest v18 inner every field read below stays inside (the last one is the
/// f32 at 105).
///
/// This, not [kGen5V18InnerLen], is the ACCEPTANCE gate. Requiring exactly 112
/// is a stricter claim than the field map needs — v18 is the only gen5 record
/// that becomes a 1 Hz sample, so if real inners are any other length the band
/// yields zero rows and everything lands in the archive, and a prior
/// lenient-decode fix on this branch exists precisely because a strict gate
/// rejected real captures.
///
/// Every fully-reassembled v18 record observed is exactly 112 bytes, so the
/// lenient floor costs nothing in steady state; it stays only to tolerate a
/// truncated / partially-reassembled delivery rather than to admit a
/// different real length.
/// A caller that wants the signal can compare against [kGen5V18InnerLen].
const int kGen5V18MinReadableLen = 109;

@Deprecated(
    'v18 inner is exactly 112 bytes, not a floor — use kGen5V18InnerLen')
const int kGen5V18MinInnerLen = kGen5V18InnerLen;

class Gen5V18Decoder implements Gen5RecordDecoder {
  const Gen5V18Decoder();

  @override
  String get name => 'gen5_v18';

  @override
  bool matches(Uint8List inner) =>
      inner.length >= kGen5V18MinReadableLen && inner[1] == 18;

  @override
  Gen5HistorySample? decode(Uint8List inner) {
    if (!matches(inner)) return null;
    final hdr = Gen5HistoricalHeader.tryParse(inner);
    if (hdr == null) return null;
    final v = _view(inner);

    // An implausible HR byte costs ONLY THE HR, same as the accel below. It
    // used to `return null`, which archived the whole record undecoded — so one
    // artefact bpm also threw away that second's R-R beats, skin temp, steps
    // and sleep state, and the band then trimmed them. 0 is the stack's
    // hr-absent sentinel (`hr == 0` is the off-skin/no-reading case every
    // consumer already gates on), so the rest of the second survives.
    final hrRaw = inner[14];
    final hr = (hrRaw >= 25 && hrRaw <= 230) ? hrRaw : 0;

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

    // An unusable accel costs ONLY THE ACCEL. It used to cost the whole record
    // (`return null` ⇒ archived undecoded) because the store could not say
    // "absent"; it can now, so HR/RR/steps/temp from the same second survive.
    //
    // NO GEN4 BOUND ON THIS FIELD. The window that used to sit here
    // (magSq ∈ [0.25, 3.24], i.e. 0.5–1.8 g) is gen4's, and it is a bound on a
    // NORMALISED GRAVITY VECTOR. Gen5's is a different physical quantity — the
    // per-axis means of raw accel — so a wrist in hard motion legitimately
    // exceeds it, and applying it here rejected exactly the workout seconds
    // that matter. All that is left is a full-scale sanity check: the axes come
    // off a ±16 g part, so anything beyond that is a mis-framed decode, not a
    // reading. Gen5 is HARDWARE-UNTESTED; this is UNVERIFIED either way, and
    // absence is the loud-not-silent answer.
    const fullScaleG = 16.0;
    final dynAccel = _round(v.getFloat32(33, Endian.little), 4);
    final gx = _round(v.getFloat32(37, Endian.little), 4);
    final gy = _round(v.getFloat32(41, Endian.little), 4);
    final gz = _round(v.getFloat32(45, Endian.little), 4);
    final gravityOk = gx.isFinite &&
        gy.isFinite &&
        gz.isFinite &&
        gx.abs() <= fullScaleG &&
        gy.abs() <= fullScaleG &&
        gz.abs() <= fullScaleG;
    final dynOk = dynAccel.isFinite && dynAccel >= 0 && dynAccel <= fullScaleG;

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
      dynamicAccelerationG: dynOk ? dynAccel : null,
      gravityG: gravityOk ? [gx, gy, gz] : const [],
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
      pdMeanB: inner[98],
      pdMeanA: inner[99],
      psnrB: inner[100] >= 128 ? inner[100] - 256 : inner[100],
      psnrA: inner[101] >= 128 ? inner[101] - 256 : inner[101],
      signalQualityLogVariance:
          _finiteOrNull(_round(v.getFloat32(105, Endian.little), 4)),
    );
  }
}

// ── v20 — 6-channel raw optical deep buffer (R22 opt-in only). ─────────────

/// One of the 5 fixed 422-byte blocks in a v20 buffer — one AFE channel, its
/// LED drive configuration, and its two photodiode sample slots. See
/// [Gen5OpticalBuffer] for which channel each block index is.
///
/// Blocks 0/3/4 carry samples on most records (`activeSampleCount ∈
/// {0, 25}`); blocks 1 and 2 usually read empty but DO occasionally carry a
/// full 25-sample window, so no block may be skipped on the assumption it is
/// structurally dead.
///
/// [channel0]/[channel1] are the block's two DETECTOR PATHS — stream A is
/// TIA 1 and stream B is TIA 2, not two wavelengths and not fixed PD1/PD2:
/// which physical photodiode feeds each TIA is dynamic and must be read from
/// the descriptor ([channel0Source]/[channel1Source]). Both paths see the
/// same LED drive. The neutral names are kept deliberately.
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

  /// bytes[7:14] — the TIA 1 detector path's front-end configuration:
  /// {physical-PD source byte, u32 ADC full-scale range in µA, i16
  /// offset-current setting in 10 nA/LSB}, at descriptor-relative offsets
  /// 6/7/11 of the 20-byte per-block descriptor. See
  /// [channel0Source], [channel0AdcRange], [tia1OffsetCurrentRaw].
  final Uint8List channel0MetaRaw;

  /// bytes[14:21] — the TIA 2 detector path's, same three fields (descriptor
  /// relative offsets 13/14/18).
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
  int get ledACurrentRaw => _view(sharedMetaRaw).getUint16(1, Endian.little);
  int get ledACurrentMicroamps => ledACurrentRaw * 10;

  /// Which driver output LED B is wired to. @ sharedMeta[3].
  int get ledBDriverConnection => sharedMetaRaw[3];

  /// LED B drive current in units of 10 µA. @ sharedMeta[4:6] u16.
  int get ledBCurrentRaw => _view(sharedMetaRaw).getUint16(4, Endian.little);
  int get ledBCurrentMicroamps => ledBCurrentRaw * 10;

  /// Which PHYSICAL photodiode (1..4) is routed into the TIA 1 path for this
  /// block. @ channel0Meta[0] = descriptor relative 6. Routing is dynamic —
  /// stream A is not permanently PD1.
  int get channel0Source => channel0MetaRaw[0];

  /// TIA 1's ADC full-scale range, in µA. @ channel0Meta[1:5] u32
  /// (descriptor relative 7).
  int get channel0AdcRange =>
      _view(channel0MetaRaw).getUint32(1, Endian.little);

  /// TIA 1's offset-current setting, raw wire value: **signed i16, 10 nA/LSB
  /// (0.01 µA/LSB)**. @ channel0Meta[5:7] = descriptor relative 11.
  ///
  /// The driver quantizes the current to 0 / 8000 / 16000 / 24000 nA and the
  /// descriptor builder divides by ten with signed rounding, so wire values
  /// 0 / 800 / 1600 / 2400 mean 0 / 8 / 16 / 24 µA. A firmware log string
  /// labels the unscaled nA value with a "µA" suffix — that is a logging bug,
  /// not an alternative unit. [tia1OffsetCurrentNanoamps] is the same number
  /// in nA.
  int get tia1OffsetCurrentRaw =>
      _view(channel0MetaRaw).getInt16(5, Endian.little);
  int get tia1OffsetCurrentNanoamps => tia1OffsetCurrentRaw * 10;

  @Deprecated(
    'This field is the TIA 1 offset CURRENT: a signed i16 in 10 nA/LSB, not an '
    'unsigned ADC offset. Use tia1OffsetCurrentRaw / '
    'tia1OffsetCurrentNanoamps.',
  )
  int get channel0AdcOffset => tia1OffsetCurrentRaw & 0xFFFF;

  /// TIA 2's, same three fields at the same relative offsets (descriptor
  /// relative 13/14/18).
  int get channel1Source => channel1MetaRaw[0];
  int get channel1AdcRange =>
      _view(channel1MetaRaw).getUint32(1, Endian.little);

  /// TIA 2's offset-current setting — see [tia1OffsetCurrentRaw] for the unit
  /// and the quantization; @ channel1Meta[5:7] = descriptor relative 18.
  int get tia2OffsetCurrentRaw =>
      _view(channel1MetaRaw).getInt16(5, Endian.little);
  int get tia2OffsetCurrentNanoamps => tia2OffsetCurrentRaw * 10;

  @Deprecated(
    'This field is the TIA 2 offset CURRENT: a signed i16 in 10 nA/LSB, not an '
    'unsigned ADC offset. Use tia2OffsetCurrentRaw / '
    'tia2OffsetCurrentNanoamps.',
  )
  int get channel1AdcOffset => tia2OffsetCurrentRaw & 0xFFFF;
}

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
/// metadata.** Each block carries its own LED drive current and, per detector
/// path (TIA 1 / TIA 2), the ADC full-scale range in µA plus a signed
/// offset-current setting in 10 nA/LSB
/// ([Gen5OpticalBlock.ledACurrentMicroamps],
/// [Gen5OpticalBlock.channel0AdcRange],
/// [Gen5OpticalBlock.tia1OffsetCurrentNanoamps], ...), and the band re-tunes
/// them continuously. Two records whose raw counts differ may be the same optical
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

// ── v26 — the Pulse Information Packet (PIP). ──────────────────────────────
//
// Type 47 revision 26 — Pulse Information Packet: the 76-byte inner is the
// shared 13-byte header followed by a COPIED 72-byte PIP ring record.
// Body offsets below are inner offsets minus 13:
//
//   body  0  inner 13..14  u16 LE PIP state/segment counter
//   body  2  inner 15..18  first CH1 stream-A optical ADC code, i32 LE
//                          (sign-extended 20-bit: valid -524288..524287)
//   body  6  inner 19..66  24 saturated i16 LE DELTAS over a 25-sample window
//   body 54  inner 67..70  f32 LE max adjacent accel-magnitude delta, g
//   body 58  inner 71..72  u16 LE packed channel-0 processing-state word
//   body 60  inner 73      primary-flags bit-8 snapshot
//   body 61  inner 74      binary waveform-morphology acceptance result
//   body 62  inner 75      aligned inner tail, OUTSIDE the copied record
//
// This replaces an earlier reading of the same bytes (`burstIndex`@13,
// `frontEndMetaRaw`@15:17, `subChannel`@17, 24 "AC samples", `signalMetric`
// f32@67, `gainSetting`@71, `gainIndex`@72, `flagA`@73, `flagB`@74) which was
// REFUTED on hardware. Every deprecated member below says which real field its
// bytes actually belong to.
//
// The pinning facts behind this layout, all exact (every R26 record has an
// R18 twin on the shared (record_index, unix) key — zero orphans):
//
//   - inner[67:71] equals the twin R18's inner[33:37] BYTE FOR BYTE. Those
//     are the same f32; R18's is [Gen5HistorySample.dynamicAccelerationG]
//     before rounding.
//   - u16 inner[71:73] equals R18 u16 inner[67:69]
//     ([Gen5HistorySample.statusWord]).
//   - inner[73] & 0x03 equals R18 inner[73] & 0x03.
//   - inner[15:19] read as i32 LE always lands inside -524288..524287.
//     inner[17] takes ONLY the values 0x00..0x07 and 0xFD..0xFF, and
//     inner[18] ONLY 0x00 or 0xFF — the signature of a sign-extended 20-bit
//     code, not a byte field. The old `subChannel` "0..7 with rare 0xFD..0xFF
//     outliers" was byte 2 of this i32 all along (0x00..0x07 for positive
//     codes, 0xF8..0xFF for negative).
//
// The delta window is 24 deltas over 25 samples, not 24 samples: sample 0 is
// the absolute code at inner[15:19] and delta i produces sample i+1. See
// [reconstructSaturatedDeltaWindow] for why the inversion is only approximate.

/// The result of inverting a saturated-delta optical window — the encoding
/// v26 uses, and R22 tags 1, 2 and 5 as well.
///
/// It carries the reconstruction AND the evidence about how far to trust it,
/// because the wire
/// carries **no in-band signal** that a window has diverged. A caller handed a
/// bare `List<int>` cannot tell a clean window from a broken one, so this type
/// refuses to hand one over on its own.
class Gen5PpgReconstruction {
  /// The reconstructed window: `deltas.length + 1` absolute ADC codes, sample
  /// 0 being the record's own first sample. Approximate by construction — read
  /// [firstAmbiguousSampleIndex] and [outOfRangeSampleIndices] first.
  final List<int> samples;

  /// Index into [samples] of the first sample produced by a saturated delta
  /// (`-32768` or `32767`), or null if the window contains none.
  ///
  /// `-32768` and `32767` are the two i16 saturation rails: the encoder had a
  /// step it could not represent and wrote the nearer rail instead, destroying
  /// the operand. That sample and **everything after it** is ambiguous,
  /// because every later sample is the running sum of a value that is already
  /// wrong. The positive rail is rarer than the negative one but real; only
  /// the exact rail values are clamps, `±32766` and below are ordinary deltas.
  final int? firstAmbiguousSampleIndex;

  /// Indices into [samples] whose value falls outside the signed-20-bit range
  /// the optical front end can physically produce (-524288..524287).
  ///
  /// A correct reconstruction cannot produce an impossible code, so a non-empty
  /// list is PROOF that this particular inversion diverged. An empty list is
  /// not proof of the opposite — see [firstAmbiguousSampleIndex].
  final List<int> outOfRangeSampleIndices;

  const Gen5PpgReconstruction({
    required this.samples,
    required this.firstAmbiguousSampleIndex,
    required this.outOfRangeSampleIndices,
  });

  /// True when a rail delta (`-32768`/`32767`) appeared: the tail of
  /// [samples] is ambiguous.
  bool get hasSaturatedDelta => firstAmbiguousSampleIndex != null;

  /// True when at least one sample is physically impossible — this window is
  /// KNOWN to have diverged from the true series.
  bool get divergenceProven => outOfRangeSampleIndices.isNotEmpty;

  /// How many leading samples are not downstream of a saturated delta. Still
  /// only "not known to be ambiguous", never "exact".
  int get trustedSampleCount => firstAmbiguousSampleIndex ?? samples.length;

  /// The leading run of [samples] that no saturated delta has poisoned.
  List<int> get trustedSamples => samples.sublist(0, trustedSampleCount);
}

/// Physically possible optical ADC codes: the front end is a sign-extended
/// 20-bit converter (see [_signExtend20], which v20 uses on the same codes).
const int _kOpticalAdcMin = -524288;
const int _kOpticalAdcMax = 524287;

/// Invert a "first absolute sample + saturated i16 deltas" optical window by
/// cumulative sum, reporting every reason the result may be wrong.
///
/// Delta reconstruction is lossy: a small fraction of windows reconstruct to
/// codes the front end cannot physically produce, and the rate is not
/// constant, so a small sample can easily show zero divergence and mislead
/// you. Treat every window as approximate and range-check every sample —
/// which is what this function does for you.
Gen5PpgReconstruction reconstructSaturatedDeltaWindow(
  int firstSample,
  List<int> deltas,
) {
  final samples = <int>[firstSample];
  final outOfRange = <int>[];
  int? firstAmbiguous;
  if (firstSample < _kOpticalAdcMin || firstSample > _kOpticalAdcMax) {
    outOfRange.add(0);
  }
  var acc = firstSample;
  for (var i = 0; i < deltas.length; i++) {
    if (deltas[i] == -32768 || deltas[i] == 32767) firstAmbiguous ??= i + 1;
    acc += deltas[i];
    samples.add(acc);
    if (acc < _kOpticalAdcMin || acc > _kOpticalAdcMax) {
      outOfRange.add(i + 1);
    }
  }
  return Gen5PpgReconstruction(
    samples: List.unmodifiable(samples),
    firstAmbiguousSampleIndex: firstAmbiguous,
    outOfRangeSampleIndices: List.unmodifiable(outOfRange),
  );
}

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

  /// u16 LE @ inner[13:15] (frame-abs 21) — the PIP state/segment counter.
  ///
  /// R26 is episodic detector output, not a one-per-second body: episodes run
  /// exactly 40 records at 1 Hz, matching the ring/state cycle, and quiet
  /// stationary wear can produce none at all. This counter is the ring/state
  /// position within such an episode.
  final int pipStateCounter;

  /// i32 LE @ inner[15:19] (frame-abs 23) — the first CH1 stream-A optical ADC
  /// code of this record's 25-sample window, sign-extended from the front
  /// end's 20 bits.
  ///
  /// This is the ONLY absolute sample in the record; the other 24 arrive as
  /// [opticalDeltas]. Unlike v20's codes it arrives pre-sign-extended, so it is
  /// read as a plain i32 rather than through [_signExtend20].
  ///
  /// Exposed raw even when impossible, so a corrupt frame stays visible as
  /// itself rather than as a fabricated code — see [firstSampleAdcInRange] and
  /// [firstSampleAdcOrNull] for the gated reads. Real records always read in
  /// range, occasionally sitting exactly on the +524,287 clip code.
  final int firstSampleAdc;

  /// Whether [firstSampleAdc] is a code the 20-bit front end can produce
  /// (-524288..524287). False means the record is corrupt, not that the band
  /// saw something unusual.
  bool get firstSampleAdcInRange =>
      firstSampleAdc >= _kOpticalAdcMin && firstSampleAdc <= _kOpticalAdcMax;

  /// [firstSampleAdc] gated to the physically possible range, null otherwise —
  /// the honest getter, mirroring [Gen5HistorySample.activityClassKnown].
  int? get firstSampleAdcOrNull =>
      firstSampleAdcInRange ? firstSampleAdc : null;

  /// The 24 RAW saturated i16 LE deltas @ inner[19:67] (frame-abs 27),
  /// exactly as they arrived.
  ///
  /// These are DIFFERENCES, not samples: delta `i` steps sample `i` to sample
  /// `i+1` of a 25-sample window whose sample 0 is [firstSampleAdc]. `-32768`
  /// and `32767` are the i16 saturation rails, i.e. a step the encoder could
  /// not represent — see [reconstructWindow].
  ///
  /// Kept raw because the deltas are the wire truth and the reconstruction is
  /// not; a caller that wants absolute codes asks for them explicitly.
  final List<int> opticalDeltas;

  /// Invert this record's window: 25 absolute ADC codes plus the evidence
  /// about how far they can be trusted. See [reconstructSaturatedDeltaWindow].
  ///
  /// Recomputed per call rather than cached — the ambiguity bookkeeping is the
  /// point of the call, and callers that want the wire truth want
  /// [opticalDeltas].
  Gen5PpgReconstruction reconstructWindow() =>
      reconstructSaturatedDeltaWindow(firstSampleAdc, opticalDeltas);

  /// `k` in 0..99 recovered from [segmentId]'s Q15 packing — the sub-second in
  /// hundredths — or null if this record's value doesn't fit the packing.
  int? get segmentIndex {
    final k = ((segmentId * 100) / 32768).round();
    return (k >= 0 && k <= 99 && (k * 32768) ~/ 100 == segmentId) ? k : null;
  }

  /// f32 LE @ inner[67:71] (frame-abs 75) — the maximum adjacent
  /// acceleration-magnitude delta in g for this second.
  ///
  /// It is MOTION, not signal quality. It is the same f32 as R18's
  /// [Gen5HistorySample.dynamicAccelerationG] before that field's rounding:
  /// byte-for-byte identical on every paired record. The earlier
  /// reading of these bytes as a per-record `signalMetric` quality weight was
  /// wrong, and the correlation that made it look like one is just motion
  /// degrading the optical signal.
  ///
  /// Null when the bytes are not finite — v18 checks every float it reads, and
  /// so does this one, so a corrupt frame cannot put NaN/Inf into a number
  /// callers do arithmetic on.
  final double? accelDeltaG;

  /// u16 LE @ inner[71:73] (frame-abs 79) — the packed channel-0
  /// processing-state word.
  ///
  /// Identical to R18's [Gen5HistorySample.statusWord] on every paired
  /// record. Not gain: the earlier `gainSetting`/`gainIndex` pair split this
  /// one u16 down the middle.
  final int channelStateWord;

  /// Raw byte @ inner[73] (frame-abs 81) — the primary-flags bit-8 snapshot.
  ///
  /// Same source as the low two bits of R18 body 60, equal on every paired
  /// record. Kept whole; [primaryFlagsBit8Raw] is the pinned two bits.
  ///
  /// NOTE the same caveat R18 carries: these bits are NOT a wear/on-wrist
  /// reading — see [Gen5HistorySample.onWristRaw]'s deprecation.
  final int primaryFlagsByte;

  /// The low two bits of [primaryFlagsByte] — the part pinned to R18.
  int get primaryFlagsBit8Raw => primaryFlagsByte & 0x03;

  /// Raw byte @ inner[74] (frame-abs 82) — the binary waveform-morphology
  /// acceptance result.
  ///
  /// A fixed neural encoder/decoder normalizes and interpolates the 25-point
  /// waveform, then compares its mean squared reconstruction error against a
  /// threshold. Kept raw; [morphologyPass] is the decoded result.
  final int morphologyByte;

  /// Whether the band's morphology check ACCEPTED this window ([morphologyByte]
  /// == 1).
  ///
  /// It is a learned "this looks like the waveform shape we trained on" pass.
  /// It is **not** a heartbeat, a pulse onset, a beat count or any medical
  /// classification — do not count these as beats.
  bool get morphologyPass => morphologyByte == 1;

  /// Raw byte @ inner[75] (frame-abs 83) — the aligned inner tail, which sits
  /// OUTSIDE the copied 72-byte ring record.
  ///
  /// Padding to the 4-byte boundary as far as anything here knows. Exposed only
  /// so nobody has to guess whether it was decoded; it carries no field.
  final int alignedTailByte;

  /// COMPAT (deprecated): inner[13] read as a standalone "per-burst counter".
  /// It is the LOW BYTE of the u16 PIP state/segment counter, so it wraps every
  /// 256 records and drops the high half.
  @Deprecated('inner[13] is the low byte of the u16 PIP state/segment counter '
      '— use pipStateCounter')
  int get burstIndex => pipStateCounter & 0xFF;

  /// COMPAT (deprecated): inner[15:17] read as a u16 of unestablished meaning.
  /// Those two bytes are the LOW HALF of [firstSampleAdc], the window's first
  /// optical ADC code — half of a number, not a field.
  @Deprecated('inner[15:17] is the low half of the i32 first optical ADC code '
      '— use firstSampleAdc')
  int get frontEndMetaRaw => firstSampleAdc & 0xFFFF;

  /// COMPAT (deprecated): inner[17] read as a 0..7 "acquisition channel index".
  /// It is byte 2 of [firstSampleAdc]'s sign-extended i32 — 0x00..0x07 for a
  /// positive first sample, 0xF8..0xFF for a negative one. The "~0.2% outliers
  /// at 0xFD..0xFF" this field's old doc comment reported were negative codes,
  /// and the band does NOT multiplex channels through this byte.
  @Deprecated('inner[17] is byte 2 of the sign-extended i32 first optical ADC '
      'code, not a channel index — use firstSampleAdc')
  int get subChannel => (firstSampleAdc >> 16) & 0xFF;

  /// COMPAT (deprecated): the 0..7 gate over [subChannel]. There is no channel
  /// here to gate — it only ever answered "is the first sample positive?".
  @Deprecated('there is no sub-channel in a v26 record — inner[17] is part of '
      'the i32 first optical ADC code; use firstSampleAdcOrNull')
  int? get subChannelKnown {
    // ignore: deprecated_member_use_from_same_package
    final b = subChannel;
    return (b >= 0 && b <= 7) ? b : null;
  }

  /// COMPAT (deprecated): the f32 at inner[67:71] read as a signal-quality
  /// metric. It is the max adjacent accel-magnitude delta in g — motion. For a
  /// real per-second quality weight use R18's
  /// [Gen5HistorySample.signalQualityLogVariance].
  @Deprecated('inner[67:71] is the max adjacent accel-magnitude delta in g '
      '(== R18 dynamicAccelerationG), not a quality metric — use accelDeltaG')
  double? get signalMetric => accelDeltaG;

  /// COMPAT (deprecated): the two halves of [channelStateWord] read as a gain
  /// configuration. There is no gain field in a v26 record.
  @Deprecated('inner[71] is the low byte of the u16 channel-0 processing-state '
      'word (== R18 statusWord), not a gain — use channelStateWord')
  int get gainSetting => channelStateWord & 0xFF;
  @Deprecated(
      'inner[72] is the high byte of the u16 channel-0 processing-state '
      'word (== R18 statusWord), not a gain — use channelStateWord')
  int get gainIndex => (channelStateWord >> 8) & 0xFF;

  /// COMPAT (deprecated): the two trailing bytes read as unnamed flags.
  @Deprecated('inner[73] is the primary-flags bit-8 snapshot — use '
      'primaryFlagsByte / primaryFlagsBit8Raw')
  int get flagA => primaryFlagsByte;
  @Deprecated('inner[74] is the binary waveform-morphology acceptance result '
      '(NOT a heartbeat) — use morphologyPass / morphologyByte')
  int get flagB => morphologyByte;

  /// COMPAT (deprecated): the 24 i16s read as AC-coupled SAMPLES. They are
  /// DELTAS over a 25-sample window, so summing is required before anything
  /// treats them as a waveform — which is also why their per-record mean sat
  /// near zero and looked "DC-removed".
  @Deprecated('inner[19:67] holds 24 saturated i16 DELTAS, not samples — use '
      'opticalDeltas, or reconstructWindow() for absolute codes')
  List<int> get ppgWaveform => opticalDeltas;

  const Gen5PpgWaveform({
    required super.histVersion,
    required super.flags,
    required super.recordIndex,
    required super.unix,
    required super.tsSubsec,
    @Deprecated('frame-abs 19 is the u16 sub-second — use tsSubsec / subSecond')
    required this.rawByte19,
    required this.segmentId,
    required this.pipStateCounter,
    required this.firstSampleAdc,
    required this.opticalDeltas,
    required this.accelDeltaG,
    required this.channelStateWord,
    required this.primaryFlagsByte,
    required this.morphologyByte,
    required this.alignedTailByte,
  });
}

/// 24 DELTAS over a 25-sample window — see [Gen5PpgWaveform.opticalDeltas].
const int _kV26DeltaCount = 24;
const int _kV26DeltasStart = 19; // frame-abs 27, body 6

/// The EXACT inner length of a v26 record: 76 bytes — the 13-byte shared
/// header, the copied 72-byte PIP ring record's first 62 bytes (24 deltas at
/// inner[19:67] plus the trailing metadata block ending at inner[74]) and one
/// aligned tail byte at inner[75] that is outside the record.
/// An exact gate, like v20/v21: a truncated record's trailing metadata would
/// otherwise decode out of whatever bytes happened to follow.
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

    final deltas = <int>[];
    for (int i = 0; i < _kV26DeltaCount; i++) {
      deltas.add(v.getInt16(_kV26DeltasStart + 2 * i, Endian.little));
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
      // Body offsets + 13. The trailing block (67/71/73) is byte-identical
      // to the twin R18 record's 33/67/73; see this section's header comment.
      pipStateCounter: v.getUint16(13, Endian.little),
      firstSampleAdc: v.getInt32(15, Endian.little),
      opticalDeltas: List.unmodifiable(deltas),
      accelDeltaG: _finiteOrNull(v.getFloat32(67, Endian.little)),
      channelStateWord: v.getUint16(71, Endian.little),
      primaryFlagsByte: inner[73],
      morphologyByte: inner[74],
      alignedTailByte: inner[75],
    );
  }
}

// ── v22 — research/diagnostic telemetry, six tagged body layouts. ──────────
//
// Revision 22: WHOOP 5.0 emits a 188-byte full frame = 176-byte inner =
// 163-byte body, and BODY BYTE 0 (inner[13]) selects one of six layouts.
// Anything the layouts below could not prove is exposed as RAW BYTES, never
// as a named field — see [Gen5ResearchRecord.rawBody].
//
// STRUCTURAL FACTS this section leans on:
//
//   * The inner length is exactly 176 — one value, no spread. The "184-byte"
//     expectation some third-party clients carry is stale.
//   * Every R22 has an exact (record_index, unix) R18 twin — which is what
//     makes the byte-for-byte cross-checks below possible.
//   * The 50 Hz optical case (inner[2] bit 7 clear) is unverified, so no
//     usable-sample count may be hardcoded from the 25 Hz shape.
//   * inner[14] always reads 0x00.
//
// THE WRITER IS NOT THE TAG. Variant 3 falls back to tag 2 when both leading
// CH2 A/B words are zero, and variant 5 falls back to tag 4 when no completed
// PIP record is available — bands configured for a variant routinely emit
// mostly the fallback tag. Dispatch on the EMITTED tag byte, never on the
// configured selector (`enable_r22_packets`, priority v6→v5→v4→v3→v2→1).
//
// STALE BYTES ARE NOT ZERO PADDING: on tag-5 records, inner[83:176] is
// BYTE-IDENTICAL to the previous R22 packet (a tag-4 body for the first one).
// The float-shaped constants sitting at inner[118:140] of every tag-5 record
// are leftover tag-4 metadata. A decoder that read the tag-1/2/4 metadata
// offsets out of a tag-5 body would report the PREVIOUS packet's accel and
// state values as this record's. That is why every accessor here is gated on
// the tag and returns null off it.

/// One "first absolute sample + saturated i16 deltas" optical window out of an
/// R22 body — the same encoding v26 uses, inheriting the same lossy-delta
/// caveat.
class Gen5ResearchOpticalWindow {
  /// Inner offset of this window's i32 first sample — carried so a caller can
  /// tie a decoded window back to the bytes it came from.
  final int innerOffset;

  /// The window's only absolute ADC code, i32 LE, sign-extended from the front
  /// end's 20 bits.
  ///
  /// Exposed raw even when impossible, exactly like [Gen5PpgWaveform] — see
  /// [firstSampleAdcOrNull] for the gated read. Real windows occasionally sit
  /// exactly on the +524,287 clip code.
  final int firstSampleAdc;

  /// The RAW saturated i16 LE deltas, exactly as they arrived. `-32768` and
  /// `32767` are the saturation rails — see [reconstructSaturatedDeltaWindow].
  ///
  /// The SLOT COUNT is a layout constant; the USABLE SAMPLE COUNT is not, and
  /// nothing on the wire carries it — there is no valid-count field. Most
  /// windows end at a rail delta well before the last slot, some carry no
  /// rail at all, and the per-tag window lengths differ, so consumers must
  /// treat the rail as the end-of-band marker rather than assume a fixed
  /// usable length.
  final List<int> deltas;

  const Gen5ResearchOpticalWindow({
    required this.innerOffset,
    required this.firstSampleAdc,
    required this.deltas,
  });

  /// Whether [firstSampleAdc] is a code the 20-bit front end can produce.
  bool get firstSampleAdcInRange =>
      firstSampleAdc >= _kOpticalAdcMin && firstSampleAdc <= _kOpticalAdcMax;

  /// [firstSampleAdc] gated to the physically possible range, null otherwise.
  int? get firstSampleAdcOrNull =>
      firstSampleAdcInRange ? firstSampleAdc : null;

  /// True when this window sits on the +524,287 clip code with every IN-BAND
  /// delta zero — a window that carries no information at all.
  ///
  /// It reconstructs to a perfectly flat, perfectly "valid-looking" line, so
  /// nothing downstream can tell it from a real flat signal without this check.
  ///
  /// "In-band" means up to the first rail delta (`-32768`/`32767`): the slots
  /// past it are padding or stale bytes and say nothing about the channel.
  bool get isClippedFlat {
    if (firstSampleAdc != _kOpticalAdcMax) return false;
    for (final d in deltas) {
      if (d == -32768 || d == 32767) return true;
      if (d != 0) return false;
    }
    return true;
  }

  /// Invert this window: `deltas.length + 1` absolute codes plus the evidence
  /// about how far they can be trusted. See [reconstructSaturatedDeltaWindow].
  Gen5PpgReconstruction reconstructWindow() =>
      reconstructSaturatedDeltaWindow(firstSampleAdc, deltas);
}

/// A decoded gen5 **revision 22** research/diagnostic record.
///
/// R22 is research telemetry, not a locally decoded health metric — it
/// belongs to the band's research accumulator, and no physiological decoder
/// for it is known to exist anywhere. Its contents are still real sensor
/// data. Nothing in this package derives a metric from it.
///
/// [tag] selects the layout, [rawBody] is ALWAYS retained, and every typed
/// accessor returns null when this record's tag does not carry that field.
/// An unknown or future tag decodes to header + [tag] + [rawBody] and nothing
/// else, which is the honest result rather than a decode failure.
class Gen5ResearchRecord extends Gen5HistoricalRecord {
  /// Body byte 0 (inner[13]) — the layout selector. Observed values 1..6.
  ///
  /// This is the EMITTED tag, which is what a decoder must key on: the
  /// configured writer can fall back (3→2, 5→4) without changing the config.
  final int tag;

  /// The whole 163-byte body (inner[13:176]) exactly as it arrived, tag byte
  /// included.
  ///
  /// Always populated, for every tag, including tags this package has no field
  /// map for. Two reasons it is not optional: most of an R22 body is either
  /// unproven or stale, and only the raw bytes let a later analysis revisit
  /// this record without a re-capture.
  ///
  /// Read it with the stale-bytes rule in mind — bytes a variant does not
  /// write hold the PREVIOUS packet's content, not zeros (tag-5 bodies repeat
  /// the previous packet's inner[83:176] verbatim).
  final Uint8List rawBody;

  /// Every optical window this record's tag carries, in body order.
  ///
  /// - tags 1, 2, 4: one window — i32 @inner[15:19] + 49 delta slots
  ///   @inner[19:117].
  /// - tag 3: two windows — i32 @inner[15:19] + 24 slots @inner[19:67], and
  ///   i32 @inner[67:71] + 24 slots @inner[71:119]. Likely the CH2 A and
  ///   CH4 A windows; this package does not name the channels, because
  ///   nothing proves which is which.
  /// - tag 5: one window inside the embedded PIP ring record — i32
  ///   @inner[23:27] + 24 slots @inner[27:75].
  /// - tag 6 and unknown tags: empty.
  final List<Gen5ResearchOpticalWindow> opticalWindows;

  /// f32 LE — the maximum adjacent acceleration-magnitude delta in g, the same
  /// float R18 carries at inner[33:37]
  /// ([Gen5HistorySample.dynamicAccelerationG] before its rounding).
  ///
  /// Byte-identical to the twin R18's on every checked tag-1/2/4 record
  /// (inner[121:125]) and tag-3 record (inner[123:127]).
  ///
  /// For tag 5 this is the EMBEDDED ring record's own value at inner[75:79],
  /// and it matches the R18 of [pipRecordUnix]'s second — NOT the carrier
  /// packet's second. Comparing it against the carrier's R18 fails.
  ///
  /// Null when this tag has no such field, or when the bytes are not finite.
  final double? accelDeltaG;

  /// u16 LE — the packed channel-0 processing-state word, the same u16 R18
  /// carries at inner[67:69] ([Gen5HistorySample.statusWord]).
  ///
  /// Byte-identical to the twin R18's on every checked tag-1/2/4 record
  /// (inner[137:139]) and tag-3 record (inner[139:141]); tag 5 carries the
  /// embedded record's own at inner[79:81], matching the R18 of
  /// [pipRecordUnix]'s second.
  final int? channelStateWord;

  /// The primary-flags bit-8 snapshot — the same field v26 carries at its body
  /// 60 ([Gen5PpgWaveform.primaryFlagsByte]).
  ///
  /// inner[143] (tags 1/2/4), inner[145] (tag 3), inner[81] (tag 5). Its low
  /// two bits equal the twin R18's `inner[73] & 3` on every checked record of
  /// all three shapes, and the byte itself only ever holds 0 or 1. Not a
  /// trivial match: R18 inner[73] takes many distinct values and its &3
  /// result splits well between 0 and 1.
  ///
  /// Same caveat R18 and v26 carry: these bits are NOT a wear/on-wrist reading.
  final int? primaryFlagsByte;

  /// The low two bits of [primaryFlagsByte] — the part pinned to R18.
  int? get primaryFlagsBit8Raw {
    final b = primaryFlagsByte;
    return b == null ? null : b & 0x03;
  }

  /// A SECOND, wider flags byte at inner[118] (tags 1/2/4) or inner[120]
  /// (tag 3), of which only the low two bits are established.
  ///
  /// Those two bits equal the twin R18's `inner[73] & 3` on every checked
  /// record — the same two bits [primaryFlagsByte] carries. The byte itself
  /// is a different quantity: it takes dozens of distinct values (96, 0, 97,
  /// 224, 32, 113, 112, 64, …) and rarely equals [primaryFlagsByte]. The
  /// upper six bits are NOT decoded here because nothing proves what they
  /// are.
  ///
  /// Tag 5 has no equivalent — its body region is the embedded ring record.
  final int? flagsSnapshotByte;

  /// The three further float32-shaped values that follow [accelDeltaG] in the
  /// metadata block, at +8/+12/+16 from it — inner[125], [129], [133] for
  /// tags 1/2/4 and inner[127], [131], [135] for tag 3.
  ///
  /// **Deliberately unnamed.** They are finite and nonzero on every checked
  /// record, almost always with |v| ≤ 1, which is what makes "these are
  /// float32s" credible — but nothing identifies what they measure. An entry
  /// is null when its bytes are not finite. Empty for tags that have no
  /// metadata block.
  final List<double?> unnamedMetadataFloats;

  /// TAG 5 ONLY — the unix second of the COMPLETED PIP ring record embedded in
  /// this body, u32 LE @inner[15:19].
  ///
  /// It is not the carrier packet's timestamp: across the 20 retained tag-5
  /// records the carrier's unix runs tens of seconds AHEAD of this value,
  /// while this value itself steps by exactly 1 s per record. Every R18
  /// cross-check on a tag-5 body only holds against the R18 of THIS second.
  ///
  /// Null for every other tag.
  final int? pipRecordUnix;

  /// TAG 6 ONLY — 25 raw i16 LE acceleration samples per axis, X then Y then Z,
  /// at inner[18:68], inner[68:118] and inner[118:168].
  ///
  /// Empty for every other tag. Multiply by [kGen5AccelScaleG] for g — or read
  /// [accelXg]/[accelYg]/[accelZg].
  ///
  /// The alignment is proven by within-axis smoothness, not by magnitude:
  /// sliding the window by one sample keeps ‖a‖ near 1 g, so the
  /// discriminator is the worst within-axis step, which is smallest at
  /// offset 18 and an order of magnitude worse at every odd offset. At
  /// 4096 LSB/g the mean magnitude at rest lands just above 1 g.
  final List<int> accelRawX;
  final List<int> accelRawY;
  final List<int> accelRawZ;

  /// [accelRawX]/[accelRawY]/[accelRawZ] in g — scale [kGen5AccelScaleG], the
  /// same 1/4096 the v21 IMU buffer uses.
  List<double> get accelXg =>
      accelRawX.map((s) => s * kGen5AccelScaleG).toList(growable: false);
  List<double> get accelYg =>
      accelRawY.map((s) => s * kGen5AccelScaleG).toList(growable: false);
  List<double> get accelZg =>
      accelRawZ.map((s) => s * kGen5AccelScaleG).toList(growable: false);

  /// TAG 6 ONLY — inner[168:176] verbatim, the eight bytes after the Z axis.
  ///
  /// A "three per-axis sign-transition counters" reading has been proposed
  /// for these bytes, and inner[168..170] do hold small values (0..14) that
  /// look like counts. The literal reading is REFUTED: raw per-axis
  /// sign-transition counts rarely match those bytes (all three axes can be
  /// strictly positive while the bytes are nonzero, where a raw sign count
  /// would be zero), and mean-removed and first-difference sign counts fail
  /// too. So the bytes are handed over raw and NOT named. inner[171] and
  /// inner[173:176] always read 0; inner[172] holds values around 100..122.
  ///
  /// Empty for every other tag.
  final Uint8List accelTailRaw;

  /// TAGS 2 and 4 ONLY — inner[144:155] verbatim.
  ///
  /// This region has been described as tag 2's "two saturated u8 metrics and
  /// four converted u16" (10 bytes). Its LOCATION is pinned — tags 2 and 4
  /// write inner[145:148] and inner[149:155] while tag 1 leaves all of
  /// inner[144:176] zero — but nothing establishes the field split or the
  /// conversion, so nothing inside is named. inner[144] and inner[148] are
  /// 0x00 throughout.
  ///
  /// A proposed extra tag-4 "per-channel table/config" shows up as exactly
  /// two further live bytes over tag 2, inner[139] and inner[159]; two bytes
  /// is not a table, so they stay inside [rawBody] only.
  ///
  /// Empty for every other tag.
  final Uint8List extendedMetricsRaw;

  const Gen5ResearchRecord({
    required super.histVersion,
    required super.flags,
    required super.recordIndex,
    required super.unix,
    required super.tsSubsec,
    required this.tag,
    required this.rawBody,
    required this.opticalWindows,
    required this.accelDeltaG,
    required this.channelStateWord,
    required this.primaryFlagsByte,
    required this.flagsSnapshotByte,
    required this.unnamedMetadataFloats,
    required this.pipRecordUnix,
    required this.accelRawX,
    required this.accelRawY,
    required this.accelRawZ,
    required this.accelTailRaw,
    required this.extendedMetricsRaw,
  });

  /// True when this package has a field map for [tag]. False means the record
  /// still decoded — header, [tag] and [rawBody] are all there — but no typed
  /// accessor applies.
  bool get hasKnownLayout => kGen5V22KnownTags.contains(tag);
}

/// The EXACT inner length of an R22 record: 176 bytes (188-byte full frame,
/// 163-byte body). One exact value with no spread; an exact gate
/// like v20/v21/v26's, because a truncated body would otherwise decode its
/// trailing metadata out of whatever bytes happened to follow.
const int kGen5V22InnerLen = 176;

/// The body tags [Gen5V22Decoder] has a verified field map for.
const Set<int> kGen5V22KnownTags = {1, 2, 3, 4, 5, 6};

// Body-tag geometry, all INNER offsets (body N == inner N+13).
const int _kV22TagOffset = 13; // body 0 — the layout selector
const int _kV22BodyStart = 13;

// tags 1/2/4: one window, then a metadata block at inner[117].
const int _kV22WideWindowStart = 15;
const int _kV22WideWindowSlots = 49;
const int _kV22WideMetaBase = 117;

// tag 3: two 24-slot windows, then the SAME metadata block shifted +2 (which is
// exactly what 4 + 24*2 = 52 bytes per window predicts: 15 + 104 = 119). All
// four R18 mirrors line up at +2, which is what proves the shift.
const int _kV22Tag3WindowAStart = 15;
const int _kV22Tag3WindowBStart = 67;
const int _kV22Tag3WindowSlots = 24;
const int _kV22Tag3MetaBase = 119;

// tag 5: an embedded PIP ring record. Mapping inner[21] onto R26's body 0
// reproduces the whole v26 layout — body 2 → 23, body 6 → 27, body 54 → 75,
// body 58 → 79, body 60 → 81, body 61 → 82.
const int _kV22Tag5RingUnix = 15;
const int _kV22Tag5WindowStart = 23;
const int _kV22Tag5WindowSlots = 24;
const int _kV22Tag5AccelDelta = 75;
const int _kV22Tag5StateWord = 79;
const int _kV22Tag5PrimaryFlags = 81;

// tag 6: three 25-sample i16 axes, then an 8-byte tail.
const int _kV22Tag6AxisStart = 18;
const int _kV22Tag6AxisSamples = 25;
const int _kV22Tag6AxisStride = 2 * _kV22Tag6AxisSamples; // 50 bytes per axis
const int _kV22Tag6TailStart = 168;

// Offsets INSIDE the tags-1/2/4/3 metadata block, relative to its base.
const int _kV22MetaFlagsSnapshot = 1; // base + 1
const int _kV22MetaAccelDelta = 4; // base + 4  (f32)
const int _kV22MetaFloat1 = 8; // base + 8  (f32, unnamed)
const int _kV22MetaFloat2 = 12; // base + 12 (f32, unnamed)
const int _kV22MetaFloat3 = 16; // base + 16 (f32, unnamed)
const int _kV22MetaStateWord = 20; // base + 20 (u16)
const int _kV22MetaPrimaryFlags = 26; // base + 26

// tags 2/4's located-but-unsplit extension region.
const int _kV22ExtendedStart = 144;
const int _kV22ExtendedEnd = 155;

class Gen5V22Decoder implements Gen5RecordDecoder {
  const Gen5V22Decoder();

  @override
  String get name => 'gen5_v22';

  @override
  bool matches(Uint8List inner) =>
      inner.length == kGen5V22InnerLen && inner[1] == 22;

  @override
  Gen5ResearchRecord? decode(Uint8List inner) {
    if (!matches(inner)) return null;
    final hdr = Gen5HistoricalHeader.tryParse(inner);
    if (hdr == null) return null;
    final v = _view(inner);
    final tag = inner[_kV22TagOffset];

    Gen5ResearchOpticalWindow window(int start, int slots) {
      final deltas = <int>[];
      for (int i = 0; i < slots; i++) {
        deltas.add(v.getInt16(start + 4 + 2 * i, Endian.little));
      }
      return Gen5ResearchOpticalWindow(
        innerOffset: start,
        firstSampleAdc: v.getInt32(start, Endian.little),
        deltas: List<int>.unmodifiable(deltas),
      );
    }

    final windows = <Gen5ResearchOpticalWindow>[];
    double? accelDeltaG;
    int? stateWord;
    int? primaryFlags;
    int? flagsSnapshot;
    var floats = const <double?>[];
    int? pipUnix;
    var accelX = const <int>[];
    var accelY = const <int>[];
    var accelZ = const <int>[];
    var accelTail = Uint8List(0);
    var extended = Uint8List(0);

    // The metadata block tags 1/2/3/4 share, at `base`. Off-tag reads are
    // what the stale-bytes rule punishes: a tag-5 body's inner[117:176] is
    // the PREVIOUS packet's bytes, so this is only ever called on a tag that
    // writes it.
    void readMetaBlock(int base) {
      flagsSnapshot = inner[base + _kV22MetaFlagsSnapshot];
      accelDeltaG = _finiteOrNull(
        v.getFloat32(base + _kV22MetaAccelDelta, Endian.little),
      );
      floats = List<double?>.unmodifiable([
        _finiteOrNull(v.getFloat32(base + _kV22MetaFloat1, Endian.little)),
        _finiteOrNull(v.getFloat32(base + _kV22MetaFloat2, Endian.little)),
        _finiteOrNull(v.getFloat32(base + _kV22MetaFloat3, Endian.little)),
      ]);
      stateWord = v.getUint16(base + _kV22MetaStateWord, Endian.little);
      primaryFlags = inner[base + _kV22MetaPrimaryFlags];
    }

    switch (tag) {
      case 1:
      case 2:
      case 4:
        windows.add(window(_kV22WideWindowStart, _kV22WideWindowSlots));
        readMetaBlock(_kV22WideMetaBase);
        if (tag != 1) {
          extended = Uint8List.fromList(
            inner.sublist(_kV22ExtendedStart, _kV22ExtendedEnd),
          );
        }
        break;
      case 3:
        windows.add(window(_kV22Tag3WindowAStart, _kV22Tag3WindowSlots));
        windows.add(window(_kV22Tag3WindowBStart, _kV22Tag3WindowSlots));
        readMetaBlock(_kV22Tag3MetaBase);
        break;
      case 5:
        pipUnix = v.getUint32(_kV22Tag5RingUnix, Endian.little);
        windows.add(window(_kV22Tag5WindowStart, _kV22Tag5WindowSlots));
        accelDeltaG = _finiteOrNull(
          v.getFloat32(_kV22Tag5AccelDelta, Endian.little),
        );
        stateWord = v.getUint16(_kV22Tag5StateWord, Endian.little);
        primaryFlags = inner[_kV22Tag5PrimaryFlags];
        break;
      case 6:
        List<int> axis(int start) {
          final out = <int>[];
          for (int i = 0; i < _kV22Tag6AxisSamples; i++) {
            out.add(v.getInt16(start + 2 * i, Endian.little));
          }
          return List<int>.unmodifiable(out);
        }

        accelX = axis(_kV22Tag6AxisStart);
        accelY = axis(_kV22Tag6AxisStart + _kV22Tag6AxisStride);
        accelZ = axis(_kV22Tag6AxisStart + 2 * _kV22Tag6AxisStride);
        accelTail = Uint8List.fromList(
          inner.sublist(_kV22Tag6TailStart, kGen5V22InnerLen),
        );
        break;
      default:
        // Unknown/future tag: header + tag + rawBody, and nothing invented.
        break;
    }

    return Gen5ResearchRecord(
      histVersion: hdr.version,
      flags: hdr.flags,
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
      tsSubsec: v.getUint16(11, Endian.little),
      tag: tag,
      rawBody: Uint8List.fromList(
        inner.sublist(_kV22BodyStart, kGen5V22InnerLen),
      ),
      opticalWindows: List<Gen5ResearchOpticalWindow>.unmodifiable(windows),
      accelDeltaG: accelDeltaG,
      channelStateWord: stateWord,
      primaryFlagsByte: primaryFlags,
      flagsSnapshotByte: flagsSnapshot,
      unnamedMetadataFloats: floats,
      pipRecordUnix: pipUnix,
      accelRawX: accelX,
      accelRawY: accelY,
      accelRawZ: accelZ,
      accelTailRaw: accelTail,
      extendedMetricsRaw: extended,
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
const Gen5V22Decoder _v22Decoder = Gen5V22Decoder();
const Gen5V26Decoder _v26Decoder = Gen5V26Decoder();

/// Every gen5 historical-record decoder this package knows, in dispatch
/// order. v21 is checked FIRST (see [parseGen5Historical]) because it cannot
/// be trusted via `hist_version` at all; the others dispatch off the version
/// byte for speed once v21 is ruled out.
const List<Gen5RecordDecoder> kGen5HistoricalDecoders = [
  _v21Decoder,
  _v18Decoder,
  _v20Decoder,
  _v22Decoder,
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
    case 22:
      // R22 is opt-in research telemetry (`enable_r22_packets`), so most
      // straps never emit it. Decoding it here returns a [Gen5ResearchRecord]
      // instead of null — callers that key on the concrete record type (edge's
      // `sampleFromGen5Historical` only maps [Gen5HistorySample]) are unaffected
      // and keep archiving the raw bytes.
      return _v22Decoder.decode(inner);
    case 26:
      return _v26Decoder.decode(inner);
    default:
      return null;
  }
}
