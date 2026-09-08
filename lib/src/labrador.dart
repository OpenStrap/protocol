// labrador.dart — WHOOP MG Labrador records: the filtered ECG (revision 17)
// and the raw ECG (revision 16).
//
// Evidence: official Android 5.458.0 Labrador parser + exact 50.41.1.0
// firmware constructor, physically closed on a WHOOP MG
// (reversing-whoop docs/mg/02, docs/mg/05). Every field below is the
// source-proven use; bytes past the sample block are preserved but NOT named.
//
// Deliberately NOT part of the gen5 historical decoder family
// (gen5_records.dart): R17 arrives LIVE as packet type 43 (REALTIME_RAW_DATA)
// on the official foreground path, which that type-47-only dispatch never
// sees; and the family's base `flags` (inner[2]) / `ppgSampleRateHz` would
// name a byte this record gives no meaning to. R17 has its own flags byte at
// inner[14].
//
// PURE Dart — dart:typed_data only.

import 'dart:typed_data';

import 'constants.dart';
import 'framing.dart';

ByteData _view(Uint8List b) =>
    b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);

/// R17 inner[14] — HeartKey S2 state/transition and presence bits.
class LabradorFlags {
  final int raw;
  const LabradorFlags(this.raw);

  /// bit 0 — entering S2 state 1.
  bool get enteringS2One => (raw & 0x01) != 0;

  /// bit 1 — current S2 state is 1. The official reducer appends ordinary
  /// active frames only while this is set; a valid active frame with it clear
  /// is the distinct explicit-RESTART branch.
  bool get currentS2One => (raw & 0x02) != 0;

  /// bit 2 — S2 transition 1 -> 2 (physically `0x0c` on the terminal frame).
  bool get s2Transition1to2 => (raw & 0x04) != 0;

  /// bit 3 — HeartKey presence (electrode contact, debounced by the band).
  bool get presence => (raw & 0x08) != 0;

  @override
  String toString() => 'LabradorFlags(0x${raw.toRadixString(16)})';
}

/// R17 inner[18] — HeartKey unreadable-reason mask.
class LabradorUnreadableMask {
  final int raw;
  const LabradorUnreadableMask(this.raw);

  bool get lowAmplitude => (raw & 0x01) != 0;
  bool get significantNoise => (raw & 0x02) != 0;
  bool get unstableSignal => (raw & 0x04) != 0;
  bool get notEnoughData => (raw & 0x08) != 0;

  /// The set bits by name, in bit order. Bits above 3 are reported as
  /// `unknown_bits_0x..` rather than given a meaning.
  List<String> get reasons => [
        if (lowAmplitude) 'low_amplitude',
        if (significantNoise) 'significant_noise',
        if (unstableSignal) 'unstable_signal',
        if (notEnoughData) 'not_enough_data',
        if ((raw & ~0x0F) != 0)
          'unknown_bits_0x${(raw & ~0x0F).toRadixString(16).padLeft(2, '0')}',
      ];

  @override
  String toString() => 'LabradorUnreadableMask(0x${raw.toRadixString(16)})';
}

/// One Labrador revision-17 packet: the band's live filtered-ECG cycle.
///
/// [samples] are 100 Hz filtered/decimated input-referred INTEGER MICROVOLTS
/// exactly as transmitted: signed i16, no rescaling and no wrist-dependent
/// sign flip (the wrist selector acts inside the AFE). No anatomical lead or
/// polarity is claimed. [variabilityRaw] has no proven unit and is not a
/// category input.
class LabradorR17 {
  static const int revision = 17;

  /// Fixed fields occupy inner[0..25]; samples start at 26.
  static const int fixedLen = 26;

  /// Physical wire capacity: 100 i16 samples per packet.
  static const int maxSamples = 100;

  /// `0xffff` at inner[21..22] means the variability value is unavailable.
  static const int variabilityUnavailable = 0xffff;

  /// inner[0]: 43 (REALTIME_RAW_DATA, the official live path) or 47
  /// (HISTORICAL_DATA — a stored R17, which the official foreground flow never
  /// enables; see [parse]'s `allowStored`).
  final int packetType;

  /// inner[2] — a generic packet-context marker the official R17 consumer
  /// ignores (`0x80` on the first all-zero boundary packet). Kept raw.
  final int headerSecondary;

  final int sequence; // inner[3..6] u32 LE data-cycle sequence
  final int strapSeconds; // inner[7..10] u32 LE
  final int subseconds; // inner[11..12] u16 LE, 1/32768 s
  final int quality; // inner[13]
  final LabradorFlags flags; // inner[14]
  final int result; // inner[15] HeartKey result code (app category input)
  final int s2State; // inner[16]; 2 is terminal
  final int progress; // inner[17]; 100 terminal, 255 invalid/abort
  final LabradorUnreadableMask unreadable; // inner[18]
  final int averageHr; // inner[19] final/stored HR — persisted category input
  final int liveHr; // inner[20] current HR — live category input

  /// inner[21..22] u16 LE, or null when the wire value is [variabilityUnavailable].
  /// Twice the RMS successive difference over 30 callback values (firmware);
  /// the callback unit is unresolved, so no physiological unit is exposed.
  final int? variabilityRaw;
  final int reserved; // inner[23]
  final int sampleCount; // inner[24..25] u16 LE, <= [maxSamples]
  final Int16List samples; // inner[26..26+2n)

  /// Aligned bytes after the sample block, byte-exact, meaning unassigned.
  final Uint8List tail;

  /// The exact inner packet these fields were read from.
  final Uint8List inner;

  const LabradorR17({
    required this.packetType,
    required this.headerSecondary,
    required this.sequence,
    required this.strapSeconds,
    required this.subseconds,
    required this.quality,
    required this.flags,
    required this.result,
    required this.s2State,
    required this.progress,
    required this.unreadable,
    required this.averageHr,
    required this.liveHr,
    required this.variabilityRaw,
    required this.reserved,
    required this.sampleCount,
    required this.samples,
    required this.tail,
    required this.inner,
  });

  bool get presence => flags.presence;

  /// The official app's completion condition.
  bool get isTerminal => progress == 100 || s2State == 2;

  /// The official app's invalid/abort sentinel.
  bool get isInvalid => progress == 255;

  bool get isLive => packetType == PacketType.realtimeRawData;

  /// Strap acquisition-cycle time in seconds.
  double get strapTime => strapSeconds + subseconds / 32768.0;

  /// Parse an inner packet. Returns null unless it is a type-43 (or, with
  /// [allowStored], type-47) packet of data revision 17 whose declared sample
  /// block fits: fixed fields through offset 25 present, count <= 100 and
  /// `26 + 2 * count` bytes available. No fixed total length is required;
  /// bytes beyond the sample block land in [tail].
  ///
  /// CRC validity is the caller's business (see [tryParseFrame]).
  static LabradorR17? parse(Uint8List inner, {bool allowStored = false}) {
    if (inner.length < fixedLen) return null;
    final pt = inner[0];
    if (pt != PacketType.realtimeRawData &&
        !(allowStored && pt == PacketType.historicalData)) {
      return null;
    }
    if (inner[1] != revision) return null;
    final v = _view(inner);
    final count = v.getUint16(24, Endian.little);
    if (count > maxSamples) return null;
    final end = fixedLen + 2 * count;
    if (inner.length < end) return null;
    final samples = Int16List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = v.getInt16(fixedLen + 2 * i, Endian.little);
    }
    final variability = v.getUint16(21, Endian.little);
    return LabradorR17(
      packetType: pt,
      headerSecondary: inner[2],
      sequence: v.getUint32(3, Endian.little),
      strapSeconds: v.getUint32(7, Endian.little),
      subseconds: v.getUint16(11, Endian.little),
      quality: inner[13],
      flags: LabradorFlags(inner[14]),
      result: inner[15],
      s2State: inner[16],
      progress: inner[17],
      unreadable: LabradorUnreadableMask(inner[18]),
      averageHr: inner[19],
      liveHr: inner[20],
      variabilityRaw:
          variability == variabilityUnavailable ? null : variability,
      reserved: inner[23],
      sampleCount: count,
      samples: samples,
      tail: Uint8List.fromList(inner.sublist(end)),
      inner: Uint8List.fromList(inner),
    );
  }

  /// [parse] over a reassembled frame, accepting only a frame whose header
  /// CRC, payload CRC and frame revision all check out ([Frame.decodable]).
  static LabradorR17? tryParseFrame(Frame f, {bool allowStored = false}) {
    if (!f.decodable) return null;
    return parse(f.inner, allowStored: allowStored);
  }
}

/// A historical (type 47) revision-16 raw ECG record, recognised but NOT
/// decoded: only the proven common header (sequence and strap time, the same
/// offsets every gen5 data record shares) is read, and the exact inner bytes
/// are kept for durable storage. The body layout is not source-closed, so no
/// body field is invented here.
class LabradorR16Raw {
  static const int revision = 16;

  /// Physically observed sizes (1,572-byte inner, 1,584-byte frame) —
  /// documentation, not enforced: a record only needs its common header.
  static const int observedInnerLen = 1572;
  static const int observedFrameLen = 1584;

  /// The common data-record header ends after the u16 sub-second at 11..12.
  static const int headerLen = 13;

  final int sequence; // inner[3..6] u32 LE
  final int strapSeconds; // inner[7..10] u32 LE
  final int subseconds; // inner[11..12] u16 LE, 1/32768 s
  final Uint8List inner; // exact bytes

  const LabradorR16Raw({
    required this.sequence,
    required this.strapSeconds,
    required this.subseconds,
    required this.inner,
  });

  double get strapTime => strapSeconds + subseconds / 32768.0;

  /// Recognise a type-47 revision-16 inner packet; null for anything else.
  static LabradorR16Raw? tryParse(Uint8List inner) {
    if (inner.length < headerLen) return null;
    if (inner[0] != PacketType.historicalData) return null;
    if (inner[1] != revision) return null;
    final v = _view(inner);
    return LabradorR16Raw(
      sequence: v.getUint32(3, Endian.little),
      strapSeconds: v.getUint32(7, Endian.little),
      subseconds: v.getUint16(11, Endian.little),
      inner: Uint8List.fromList(inner),
    );
  }

  /// [tryParse] over a reassembled frame that passed both CRCs and the
  /// revision check.
  static LabradorR16Raw? tryParseFrame(Frame f) =>
      f.decodable ? tryParse(f.inner) : null;
}
