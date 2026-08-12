// gen5_records.dart — WHOOP 5 (gen5 / "fd4b" / "Maverick-Goose") historical
// record decoders: v18 (per-second biometric summary), v20 (6-channel raw
// optical deep buffer), v21 (100Hz 6-axis IMU deep buffer), v26 (24Hz PPG
// waveform).
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
// v20 IS THE EXCEPTION to that "confirmed independently" claim — see the loud
// warning on Gen5V20Decoder/Gen5OpticalBuffer below before trusting it.
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

/// The 11-byte header every gen5 historical record kind (v18/v20/v21/v26)
/// shares, at INNER offsets `[0:11)`:
/// ```
///   inner[0]      packet type (0x2F)
///   inner[1]      hist_version   (frame-abs 9)
///   inner[2]      layout_marker  (frame-abs 10) — raw; not deeply interpreted
///   inner[3:7]    record_index   u32 LE (frame-abs 11) — monotonic, not unix
///   inner[7:11]   unix           u32 LE (frame-abs 15)
/// ```
class Gen5HistoricalHeader {
  final int version;
  final int layoutMarker;
  final int recordIndex;
  final int unix;

  const Gen5HistoricalHeader({
    required this.version,
    required this.layoutMarker,
    required this.recordIndex,
    required this.unix,
  });

  static Gen5HistoricalHeader? tryParse(Uint8List inner) {
    if (inner.length < 11) return null;
    final v = _view(inner);
    return Gen5HistoricalHeader(
      version: inner[1],
      layoutMarker: inner[2],
      recordIndex: v.getUint32(3, Endian.little),
      unix: v.getUint32(7, Endian.little),
    );
  }
}

/// Base type every decoded gen5 historical record kind extends. Callers that
/// don't care which kind they got can still read the shared header fields.
abstract class Gen5HistoricalRecord {
  final int histVersion;
  final int recordIndex;
  final int unix;

  const Gen5HistoricalRecord({
    required this.histVersion,
    required this.recordIndex,
    required this.unix,
  });
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
  /// finite with magnitude ∈ [0.5, 1.5] g at decode time.
  final List<double> gravityG;

  /// Cumulative on-chip step counter @ inner[49:51] u16 LE (frame-abs 57).
  /// FULL 2 bytes — an earlier bug (fixed upstream, noop #132/#276) read
  /// only the low byte. No midnight reset.
  final int stepMotionCounter;

  /// Raw @ inner[51] (frame-abs 59).
  final int stepCadence;

  /// RAW byte @ inner[55] (frame-abs 63). Only 0 (still) / 1 (walk) / 2 (run)
  /// are valid activity-class codes — everything else (0xFF, 7, ...) is the
  /// strap signaling "not classified", not a fourth activity. Kept as the raw
  /// byte for diagnostics; use [activityClassKnown] for the honest, gated
  /// value (never fabricate a class out of an invalid code).
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
  /// affine scale here. @ inner[65:67] u16 LE (frame-abs 73). Confirmed
  /// worn≈30.6°C / off-wrist≈22.5°C on real captures.
  final double skinTempC;

  /// Raw, not deep-sleep markers per noop. @ inner[67/69/71] u16 LE each
  /// (frame-abs 75/77/79).
  final int statusWord;
  final int statusWord1;
  final int statusWord2;

  /// Raw @ inner[73] (frame-abs 81). Packed:
  ///   bits 0-1: on-wrist
  ///   bits 2-3: wake_quality
  ///   bits 4-5: sleep_state — 0 wake / 1 still / 2 sleep / 3 up. Prefer
  ///     [sleepState] over reading the nibble yourself. whoop-rs's
  ///     "0 still / 1 wake" is the wrong way round.
  final int sleepStateByte;

  /// @ inner[74] (frame-abs 82). **NOT SpO2** — the name is kept only because
  /// removing it breaks the API. Treat it as an opaque sleep-gated byte.
  ///
  /// It reads 0 in 99% of records and is *identically* zero unless
  /// [sleepState] is [Gen5SleepState.sleep], where it fires on 2.4% of
  /// records. A blood-oxygen channel does not switch itself off while the
  /// band is worn. The values that do appear cluster at 95-99, which is what
  /// makes the byte look like SpO2 in the first place.
  final int spo2CandidateRaw;

  /// @ inner[98] (frame-abs 106). Proven NOT the high half of a u16 with
  /// [opticalBaselineB] (high byte steps without low-byte carry across
  /// 18,599 corpus pairs) — kept as an independent byte, never fused.
  final int opticalBaselineA;

  /// @ inner[99] (frame-abs 107). 0 = off-wrist.
  final int opticalBaselineB;

  /// @ inner[100] (frame-abs 108). 128 on BOTH [opticalAmpA] and
  /// [opticalAmpB] simultaneously is a signal-quality sentinel (never one
  /// alone in the 757/757 reference corpus) — see [isOpticalAmpSentinel].
  final int opticalAmpA;
  final int opticalAmpB;

  /// @ inner[105:109] f32 LE (frame-abs 113). Range ~-5.3..0 on the reference
  /// corpus; purpose unknown. Exposed raw, don't consume.
  final double unknownF32;

  const Gen5HistorySample({
    required super.histVersion,
    required super.recordIndex,
    required super.unix,
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
    required this.opticalBaselineA,
    required this.opticalBaselineB,
    required this.opticalAmpA,
    required this.opticalAmpB,
    required this.unknownF32,
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

  /// **Do not use — frame-abs 82 is not SpO2.** The byte is zero in 99% of
  /// records and nonzero *only* while [sleepState] is [Gen5SleepState.sleep],
  /// so this getter surfaces a plausible-looking 95-99 on 0.6% of records and
  /// null on the rest. See [spo2CandidateRaw] for the measurements.
  @Deprecated(
    'frame-abs 82 is not SpO2: zero in 99% of records and nonzero only '
    'during band-declared sleep. Read spo2CandidateRaw if you need the byte.',
  )
  int? get spo2Candidate => (spo2CandidateRaw >= 70 && spo2CandidateRaw <= 100)
      ? spo2CandidateRaw
      : null;

  /// True when both optical-amp bytes read the 128 sentinel simultaneously —
  /// per the reference corpus this means "signal quality flag", not a real
  /// amplitude reading of 128 on each channel.
  bool get isOpticalAmpSentinel => opticalAmpA == 128 && opticalAmpB == 128;

  /// bits 0-1 of [sleepStateByte].
  int get onWristRaw => sleepStateByte & 0x03;

  /// bits 2-3 of [sleepStateByte].
  int get wakeQualityRaw => (sleepStateByte >> 2) & 0x03;

  /// bits 4-5 of [sleepStateByte], raw. Prefer [sleepState].
  int get sleepStateRawNibble => (sleepStateByte >> 4) & 0x03;

  /// The band's own coarse wake/sleep state. Total over the 2-bit nibble, so
  /// never null. **A wake/sleep envelope, not a sleep stage** — see
  /// [Gen5SleepState] for the evidence and the limits.
  Gen5SleepState get sleepState =>
      Gen5SleepState.values[sleepStateRawNibble];
}

/// Minimum inner length to read every v18 field this decoder touches (the
/// last is [Gen5HistorySample.unknownF32], a f32 ending at inner byte 109).
/// Real captures are padded to a 4-byte boundary (109 → 112), so this is a
/// floor, not an exact match — unlike v20/v21 below, which DO have a fixed
/// exact size.
const int kGen5V18MinInnerLen = 109;

class Gen5V18Decoder implements Gen5RecordDecoder {
  const Gen5V18Decoder();

  @override
  String get name => 'gen5_v18';

  @override
  bool matches(Uint8List inner) =>
      inner.length >= kGen5V18MinInnerLen && inner[1] == 18;

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
    final magSq = gx * gx + gy * gy + gz * gz;
    if (magSq < 0.25 || magSq > 2.25) return null; // 0.5g..1.5g

    final unknownF32 = _round(v.getFloat32(105, Endian.little), 4);

    return Gen5HistorySample(
      histVersion: hdr.version,
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
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
      skinTempC: _round(v.getUint16(65, Endian.little) / 100.0, 2),
      statusWord: v.getUint16(67, Endian.little),
      statusWord1: v.getUint16(69, Endian.little),
      statusWord2: v.getUint16(71, Endian.little),
      sleepStateByte: inner[73],
      spo2CandidateRaw: inner[74],
      opticalBaselineA: inner[98],
      opticalBaselineB: inner[99],
      opticalAmpA: inner[100],
      opticalAmpB: inner[101],
      unknownF32: unknownF32,
    );
  }
}

// ── v20 — 6-channel raw optical deep buffer (R22 opt-in only). ─────────────

/// One of the 5 fixed 422-byte blocks in a v20 buffer. Per the reference
/// corpus (29,203 records, both sources), only blocks 0/3/4 are ever
/// active (`sampleCount ∈ {0, 25}`); blocks 1/2 are always empty. Channel
/// role assignment ("red"/"ir"/"green") is EXPLICITLY UNPROVEN by both
/// reference sources — exposed as raw `channel0`/`channel1` samples only,
/// per noop's own naming discipline (they retired 'ppg_channel'-style names).
class Gen5OpticalBlock {
  /// @ block byte 0. Shared by both channel slots. 0 or 25 in the reference
  /// corpus; capped to the 50-slot capacity of a 200-byte/4-byte-sample slot.
  final int activeSampleCount;

  /// Raw sign-extended 20-bit samples (returned as ints in [-524288, 524287]),
  /// length == [activeSampleCount].
  final List<int> channel0;
  final List<int> channel1;

  /// bytes[1:7] of the block — shared block metadata incl. a speculative
  /// LED-current field. Not decoded further; kept for re-derivation.
  final Uint8List sharedMetaRaw;

  /// bytes[7:14] — channel-0's metadata incl. a speculative offset-DAC field.
  final Uint8List channel0MetaRaw;

  /// bytes[14:21] — channel-1's metadata.
  final Uint8List channel1MetaRaw;

  const Gen5OpticalBlock({
    required this.activeSampleCount,
    required this.channel0,
    required this.channel1,
    required this.sharedMetaRaw,
    required this.channel0MetaRaw,
    required this.channel1MetaRaw,
  });
}

/// ⚠️ EXPERIMENTAL / UNVERIFIED LAYOUT — unlike v18/v21/v26, this record's
/// field layout is a genuine, UNRESOLVED disagreement between the two
/// reference implementations, and NEITHER has a real (non-synthetic)
/// hardware capture of a v20 record to break the tie:
///   - whoop-rs's model: 6 independent fixed-offset channels of 25 samples
///     each, at distinct inner offsets, gated on a green-LED-echo anchor.
///   - This decoder's model (below): 5 blocks of 422 bytes, each holding 2
///     channels of up to 50 samples, gated on a per-block sample-count byte.
/// Cross-validating this decoder against whoop-rs's own synthetic test
/// fixture produces a syntactically-valid-looking but semantically wrong
/// result — silently, with no error. DO NOT treat [Gen5OpticalBuffer]'s
/// fields as trustworthy until a real captured v20 frame resolves which
/// model (if either) is correct. Callers should treat this as low-confidence
/// / diagnostic-only data, never feed it into a metric pipeline as ground
/// truth.
class Gen5OpticalBuffer extends Gen5HistoricalRecord {
  final int layoutMarker;

  /// Always 5 entries (blocks 0-4), even the always-empty 1/2 slots — index
  /// == block number, matching the reference corpus's `sampleCount` array
  /// convention (`[25, 0, 0, 25, 25]`).
  final List<Gen5OpticalBlock> blocks;

  const Gen5OpticalBuffer({
    required super.histVersion,
    required super.recordIndex,
    required super.unix,
    required this.layoutMarker,
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

    return Gen5OpticalBuffer(
      histVersion: hdr.version,
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
      layoutMarker: hdr.layoutMarker,
      blocks: blocks,
    );
  }
}

// ── v21 — 100Hz 6-axis raw IMU buffer (R22 opt-in only). ───────────────────

/// Decoded gen5 v21 IMU buffer. High-confidence layout — exact 3-way
/// agreement between whoop-rs, noop, and this file's own byte-level
/// verification (§1.5). The 100Hz sample rate is INFERRED from the sample
/// count only, never independently measured by either reference source —
/// treat the rate itself, not the samples, as unconfirmed.
class Gen5ImuBuffer extends Gen5HistoricalRecord {
  final int layoutMarker;

  /// Must be 100 for a genuine v21 buffer — part of [Gen5V21Decoder.matches]'s
  /// gate, since (per §1.5) this record kind "has no confirmed place in the
  /// version-byte scheme" and is identified by shape, not `hist_version`.
  final int countA;
  final int countB;

  /// g, scale 1/4096 g/LSB. 100 samples each.
  final List<double> accelXg;
  final List<double> accelYg;
  final List<double> accelZg;

  /// deg/s, scale 2000/32768 dps/LSB (±2000 dps full-scale). 100 samples each.
  final List<double> gyroXdps;
  final List<double> gyroYdps;
  final List<double> gyroZdps;

  const Gen5ImuBuffer({
    required super.histVersion,
    required super.recordIndex,
    required super.unix,
    required this.layoutMarker,
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
const double _kGyroScaleDps = 2000.0 / 32768.0;
const double _kAccelScaleG = 1.0 / 4096.0;

const int _kV21CountAOffset = 16; // frame-abs 24
const int _kV21AxStart = 20; // frame-abs 28
const int _kV21CountBOffset = 622; // frame-abs 630
const int _kV21GxStart = 632; // frame-abs 640
const int _kV21SamplesPerAxis = 100;

/// Exact inner length: total on-wire frame is 1244 bytes, so padded-inner =
/// 1244 - 8 - 4 = 1232. PRIMARY identity check, along with [Gen5V21Decoder]'s
/// count==100 gate — neither the length nor the counts depend on trusting
/// `hist_version` at all, matching how both reference repos actually
/// identify this buffer.
const int kGen5V21InnerLen = _kV21GxStart + 3 * 2 * _kV21SamplesPerAxis; // 1232

class Gen5V21Decoder implements Gen5RecordDecoder {
  const Gen5V21Decoder();

  @override
  String get name => 'gen5_v21';

  @override
  bool matches(Uint8List inner) {
    if (inner.length != kGen5V21InnerLen) return false;
    final v = _view(inner);
    final countA = v.getUint16(_kV21CountAOffset, Endian.little);
    final countB = v.getUint16(_kV21CountBOffset, Endian.little);
    return countA == 100 && countB == 100;
  }

  @override
  Gen5ImuBuffer? decode(Uint8List inner) {
    if (!matches(inner)) return null;
    final hdr = Gen5HistoricalHeader.tryParse(inner);
    if (hdr == null) return null;
    final v = _view(inner);

    List<double> axis(int start, double scale) {
      final out = <double>[];
      for (int i = 0; i < _kV21SamplesPerAxis; i++) {
        out.add(v.getInt16(start + 2 * i, Endian.little) * scale);
      }
      return out;
    }

    return Gen5ImuBuffer(
      histVersion: hdr.version,
      recordIndex: hdr.recordIndex,
      unix: hdr.unix,
      layoutMarker: hdr.layoutMarker,
      countA: v.getUint16(_kV21CountAOffset, Endian.little),
      countB: v.getUint16(_kV21CountBOffset, Endian.little),
      accelXg: axis(_kV21AxStart, _kAccelScaleG),
      accelYg: axis(_kV21AxStart + 200, _kAccelScaleG),
      accelZg: axis(_kV21AxStart + 400, _kAccelScaleG),
      gyroXdps: axis(_kV21GxStart, _kGyroScaleDps),
      gyroYdps: axis(_kV21GxStart + 200, _kGyroScaleDps),
      gyroZdps: axis(_kV21GxStart + 400, _kGyroScaleDps),
    );
  }
}

// ── v26 — 24Hz single-wavelength PPG waveform. ─────────────────────────────

class Gen5PpgWaveform extends Gen5HistoricalRecord {
  final int layoutMarker;

  /// Low byte of [segmentId] @ inner[11] (frame-abs 19).
  ///
  /// This offset is a u16, not a byte: inner[12] is nonzero on 99% of real
  /// records, so reading one byte here discards most of the value. Prefer
  /// [segmentId].
  @Deprecated('frame-abs 19 is a u16 — use segmentId')
  final int rawByte19;

  /// u16 LE @ inner[11:13] (frame-abs 19), constant across the records of one
  /// burst.
  ///
  /// The value is an integer `k` in 0..99 packed as a Q15 fraction:
  /// `segmentId == (k * 32768) ~/ 100` holds for every record observed. Use
  /// [segmentIndex] for `k`. What `k` counts is not established, so it is
  /// exposed without a claim.
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

  /// `k` in 0..99 recovered from [segmentId]'s Q15 packing, or null if this
  /// record's value doesn't fit the packing.
  int? get segmentIndex {
    final k = ((segmentId * 100) / 32768).round();
    return (k >= 0 && k <= 99 && (k * 32768) ~/ 100 == segmentId) ? k : null;
  }

  /// f32 LE @ inner[67:71] (frame-abs 75). Tracks with [flagA]/[flagB] as a
  /// per-record signal-quality indicator where LOW means a clean record, but
  /// the scale is unpinned. Exposed raw.
  ///
  /// Null when the record is too short to carry the trailing metadata block
  /// (see [kGen5V26MinInnerLenWithMeta]) — never a stand-in value.
  final double? signalMetric;

  /// Front-end gain configuration @ inner[71] / inner[72] (frame-abs 79/80).
  /// Each [subChannel] runs a characteristic gain, adjusted within a range.
  /// Null on a record too short to carry it.
  final int? gainSetting;
  final int? gainIndex;

  /// Raw flag bytes @ inner[73] / inner[74] (frame-abs 81/82). Roughly
  /// complementary, and [signalMetric] is about an order of magnitude lower
  /// when [flagB] is set. Meaning otherwise unestablished — exposed raw.
  /// Null on a record too short to carry them.
  final int? flagA;
  final int? flagB;

  /// Raw AC-coupled ADC samples, no physical unit. Always 24 in practice.
  /// Every channel is DC-removed on the band: the per-record sample mean is
  /// ~0 for all values of [subChannel].
  final List<int> ppgWaveform;

  const Gen5PpgWaveform({
    required super.histVersion,
    required super.recordIndex,
    required super.unix,
    required this.layoutMarker,
    @Deprecated('frame-abs 19 is a u16 — use segmentId') required this.rawByte19,
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

/// Minimum inner length to read a full 24-sample waveform. v26's declared
/// length varies with the sample count in principle, but is always 24 in
/// practice — this is a floor, not the exact match v20/v21 use.
const int kGen5V26MinInnerLen = _kV26SamplesStart + 2 * _kV26SampleCount; // 67

/// Minimum inner length to also read the metadata block that follows the
/// waveform (signal metric, gain, flags — the last is inner[74]).
///
/// Kept separate from [kGen5V26MinInnerLen] on purpose: a record shorter than
/// this still decodes its waveform, and the trailing fields come back null
/// rather than the record being rejected. Every real record observed carries
/// an inner length of 76.
const int kGen5V26MinInnerLenWithMeta = 75;

class Gen5V26Decoder implements Gen5RecordDecoder {
  const Gen5V26Decoder();

  @override
  String get name => 'gen5_v26';

  @override
  bool matches(Uint8List inner) =>
      inner.length >= kGen5V26MinInnerLen && inner[1] == 26;

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
    final hasMeta = inner.length >= kGen5V26MinInnerLenWithMeta;

    return Gen5PpgWaveform(
      histVersion: hdr.version,
      // v26 is the ONE exception to the shared header's u32 record_index:
      // whoop-rs's ground truth (real captured frames) reads only a u16 here
      // — inner[5:7] is a separate, distinct field, not the top half of a
      // u32 counter. Reusing hdr.recordIndex (u32 @ inner[3:7]) inflates the
      // counter ~500x on real captures. Confirmed by independent
      // cross-validation against whoop-rs's real_frames.json fixtures.
      recordIndex: v.getUint16(3, Endian.little),
      unix: hdr.unix,
      layoutMarker: hdr.layoutMarker,
      // ignore: deprecated_member_use_from_same_package
      rawByte19: inner[11],
      segmentId: v.getUint16(11, Endian.little),
      burstIndex: inner[13],
      frontEndMetaRaw: v.getUint16(15, Endian.little),
      subChannel: inner[17],
      // The metadata block sits AFTER the waveform, so a short record can
      // legitimately lack it. Null out rather than reject the record or
      // invent a value.
      signalMetric: hasMeta ? v.getFloat32(67, Endian.little) : null,
      gainSetting: hasMeta ? inner[71] : null,
      gainIndex: hasMeta ? inner[72] : null,
      flagA: hasMeta ? inner[73] : null,
      flagB: hasMeta ? inner[74] : null,
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
