// v24_status.dart — the tail of a WHOOP 4 v24 historical record (inner[72:92]).
//
// PURE Dart. Separate from records.dart on purpose: R24.toMap()'s key set is
// frozen (parity oracle + shipped SQLite columns), so nothing here adds a key
// to it. This is an additional, opt-in view of bytes R24 already carries in
// rawTail.
//
// Evidence: 85,331 v24 records + simultaneous R10/R11 live captures from one
// WHOOP 4.0 (one wearer, harvard 41.17.6.0), and the v24 entries already in
// decode_parity_cases.json (recorded by the OpenStrap project: 1,887 entries,
// 629 distinct records). The structural claims that corpus can show are
// asserted in test/v24_status_test.dart.
// Offsets are INNER (packet type 0x2f at inner[0]); add 4 for frame-absolute.

import 'dart:typed_data';

/// Coarse activity state, v24 inner[80] bits 4-5 (duplicated at inner[30]
/// bits 5-6). The names are the firmware's own `SLEEPFLAG` console names.
///
/// This is the strap's coarse flag, not a sleep-stage decode: `sleep` persists
/// while the strap lies off the body.
enum V24ActivityState { wake, still, sleep, up }

/// One of the three 2-byte optical control words at v24 inner[74:80].
///
/// Each word describes one slot of the realtime R11 optical packet, and is
/// enough to rebuild that slot's 25-byte descriptor:
///
///   byte 0 bits 0-3  slot index (0, 1, 2 — constant per word)
///   byte 0 bits 4-5  lane A code   → descriptor lane parameter = code × 800
///   byte 0 bits 6-7  lane B code   → descriptor lane parameter = code × 800
///   byte 1 bits 0-3  drive code    → a per-slot lookup; 12 = configured off
///   byte 1 bits 4-7  flags
///
/// The word for slot 1 describes the R11 packet ONE RECORD LATER (22,419 /
/// 22,419 history/live pairs); same-record pairing mismatches at every
/// setting change. Physical units (LED current, offset DAC, ...) are unknown:
/// the numbers are the descriptor's, nothing more. The drive lookups were
/// built from the same captures, so they are not independent evidence.
class V24SlotControl {
  /// 0, 1 or 2 — R11 slot 1, 2 or 3.
  final int slotIndex;

  /// 0-3. The R11 descriptor's lane-A parameter is [laneAParam].
  final int laneACode;

  /// 0-3. The R11 descriptor's lane-B parameter is [laneBParam].
  final int laneBCode;

  /// 0-15. 12 means configured off; see [configuredOff] and [driveParam].
  final int driveCode;

  /// The word's high nibble of byte 1, unshifted (0x10, 0x20, 0x40, 0x80).
  final int flags;

  const V24SlotControl({
    required this.slotIndex,
    required this.laneACode,
    required this.laneBCode,
    required this.driveCode,
    required this.flags,
  });

  /// Drive code 12: the record says this slot is off. This is configuration,
  /// not a sample count: in 16 records (32 slot observations, at the end of a
  /// window) history said off while R11 still carried 50 samples. For live
  /// data read R11's own sample count.
  bool get configuredOff => driveCode == 12;

  int get laneAParam => laneACode * 800;
  int get laneBParam => laneBCode * 800;

  /// The R11 descriptor's drive parameter for this code, or null when the code
  /// has never been seen next to a live descriptor. NOT interpolated: an
  /// unseen code stays unknown.
  ///
  /// Each slot has its own table; a code seen only in another slot is unknown.
  /// Slot 1 (index 0): 3→600, 5→900, 6→1150, 7→1400, 8→1750, 9→2200,
  /// 10→2750, 11→3350. Slot 2 (index 1): 11→12750. Slot 3 (index 2): 6→4250,
  /// 10→10300.
  int? get driveParam => switch (slotIndex) {
        0 => _kSlot1Drive[driveCode],
        1 => _kSlot2Drive[driveCode],
        2 => _kSlot3Drive[driveCode],
        _ => null,
      };

  /// Slot 1 only: more than 40 of the 50 lane-A samples of the SAME record
  /// sit at the ADC ceiling 524287 (22 positives, 0 exceptions in 22,420
  /// pairs, both directions). It says nothing about lane B.
  bool get laneAClipped => slotIndex == 0 && (flags & 0x10) != 0;

  /// Slot 1 only: as [laneAClipped], for lane B (34 positives, 0 exceptions).
  /// It says nothing about lane A.
  bool get laneBClipped => slotIndex == 0 && (flags & 0x40) != 0;

  static const Map<int, int> _kSlot1Drive = {
    3: 600,
    5: 900,
    6: 1150,
    7: 1400,
    8: 1750,
    9: 2200,
    10: 2750,
    11: 3350,
  };
  static const Map<int, int> _kSlot2Drive = {11: 12750};
  static const Map<int, int> _kSlot3Drive = {6: 4250, 10: 10300};
}

/// Decoded tail of a v24 record. See [parseV24Status].
class V24Status {
  /// u16 LE @ inner[72]. Probably a temperature in tenths of a degree Celsius:
  /// on that scale it reads 34.8-35.4 in every parity-corpus record, plateaus at
  /// 33.3-33.4 on our upper arm, and read 23.0 after 36 min on a table in a room
  /// of roughly 21.5 (the AC setting). It is slow.
  /// The whole range seen is 20.6-43.8; the highest values are from around
  /// charging. There is no reference thermometer, so the scale and accuracy are
  /// not proven. It is not a core body temperature.
  final int temperatureCandidateRaw;

  /// The three optical control words, R11 slots 1, 2, 3 in that order.
  final List<V24SlotControl> slots;

  final V24ActivityState activityState;

  /// u8 @ inner[82]. Non-zero around slot 2/3 measurement windows. Values of
  /// 77-100 look like a percentage (see [percentLikeValue]); the others look
  /// like status codes. This is NOT shown to be SpO2: no reference oximeter
  /// comparison exists.
  final int measurementWindowByte;

  /// u8 @ inner[85]. Looks motion-related. It is 0 in all 237 parity-corpus
  /// records whose state is `still`. Scale unknown.
  final int motionByte;

  /// u8 @ inner[87]. Meaning unknown.
  final int sessionClassByte;

  /// u32 LE @ inner[88]. A cumulative step-like counter. The high half was 0
  /// in every record seen (max 9,045), so a u16 fits equally; the rollover and
  /// any midnight or reboot reset are unknown.
  ///
  /// Against hand-counted steps of one person it reads HIGH: +22 % on a long
  /// walk on the wrist (252 for 207), +21 % on the upper arm (429 for 356),
  /// +5 % to +41 % by gait; and 62 for 30 s of arm shaking with no steps. The
  /// first increment comes 8-20 s after the start of a walk and is 11-13, so
  /// one increment is not one step. Use differences between records; the
  /// absolute value has no known zero.
  final int stepLikeCounter;

  const V24Status({
    required this.temperatureCandidateRaw,
    required this.slots,
    required this.activityState,
    required this.measurementWindowByte,
    required this.motionByte,
    required this.sessionClassByte,
    required this.stepLikeCounter,
  });

  /// Slots 2 and 3 are both configured on. Configuration only: see
  /// [V24SlotControl.configuredOff].
  bool get slotsConfiguredOn =>
      !slots[1].configuredOff && !slots[2].configuredOff;

  /// [measurementWindowByte] when it is 77-100 AND slots 2/3 carry drive codes
  /// 11/6, else null. In 85,331 records a value in that range occurred only
  /// with that pair (482 records); every other pair, seen or unseen, gives
  /// null.
  int? get percentLikeValue =>
      slots[1].driveCode == 11 &&
              slots[2].driveCode == 6 &&
              measurementWindowByte >= 77 &&
              measurementWindowByte <= 100
          ? measurementWindowByte
          : null;
}

/// Decode inner[72:92] of a WHOOP 4 **v24** historical record.
///
/// Returns null for anything that is not a 96-byte v24 record, and for a
/// record whose three control words do not carry the slot indices 0, 1, 2 —
/// that structure held in every real record seen, so a record without it is
/// not this layout and reading its fields would be fabrication. All 85,331 of our
/// records and every corpus record are exactly 96 bytes.
V24Status? parseV24Status(Uint8List inner) {
  if (inner.length != 96 || inner[0] != 0x2f || inner[1] != 24) return null;
  final slots = <V24SlotControl>[];
  for (var i = 0; i < 3; i++) {
    final b0 = inner[74 + 2 * i];
    final b1 = inner[75 + 2 * i];
    if ((b0 & 0x0f) != i) return null;
    slots.add(V24SlotControl(
      slotIndex: i,
      laneACode: (b0 >> 4) & 3,
      laneBCode: (b0 >> 6) & 3,
      driveCode: b1 & 0x0f,
      flags: b1 & 0xf0,
    ));
  }
  final view =
      inner.buffer.asByteData(inner.offsetInBytes, inner.lengthInBytes);
  return V24Status(
    temperatureCandidateRaw: view.getUint16(72, Endian.little),
    slots: List.unmodifiable(slots),
    activityState: V24ActivityState.values[(inner[80] >> 4) & 3],
    measurementWindowByte: inner[82],
    motionByte: inner[85],
    sessionClassByte: inner[87],
    stepLikeCounter: view.getUint32(88, Endian.little),
  );
}

/// Rebuild the 25-byte R11 slot-1 descriptor (R11 inner[13:38]) that the
/// NEXT record's realtime packet carries, from a v24 record's first control
/// word. Null when the drive code has no known descriptor value.
///
///   00 32 04 <drive> 05 <drive> 01 <drive> 04 20 00 00 00 <laneA>
///   05 20 00 00 00 <laneB>            (u16 little-endian)
Uint8List? v24NextSlot1Descriptor(V24SlotControl slot1) {
  final d = slot1.slotIndex == 0 ? slot1.driveParam : null;
  if (d == null) return null;
  final a = slot1.laneAParam, b = slot1.laneBParam;
  return Uint8List.fromList([
    0x00, 0x32, 0x04, d & 0xff, d >> 8, 0x05, d & 0xff, d >> 8, 0x01, //
    d & 0xff, d >> 8, 0x04, 0x20, 0x00, 0x00, 0x00, a & 0xff, a >> 8, //
    0x05, 0x20, 0x00, 0x00, 0x00, b & 0xff, b >> 8,
  ]);
}
