// Xiaomi Mi scales: the Mi Body Composition Scale (advertises "MIBCS" /
// "MIBFS") and the Mi Smart Scale 2 ("MI SCALE2"). Plain GATT, no auth.
//
// BODY COMPOSITION SCALE — Body Composition Measurement (0x2A9C), notify,
// 13 bytes, little-endian:
//   0 flags A · 1 flags B · 2-3 year · 4 month · 5 day · 6 hour · 7 minute ·
//   8 second · 9-10 impedance (ohm) · 11-12 weight (raw)
// Flags A: bit 0 pounds. Flags B: bit 1 impedance stable, bit 5 weight
// stable, bit 6 jin, bit 7 measurement finished (a finished frame is kept).
// Impedance 65533 means the measurement failed and 65534 that it is still
// running; only an impedance-stable frame carries a real value. Several
// stable frames of one weighing share its timestamp, and the impedance
// arrives on a later one than the weight.
//
// SMART SCALE 2 — Weight Measurement (0x2A9D), 10-byte records (several may
// share one notification):
//   0 flags · 1-2 weight (raw) · 3-4 year · 5 month · 6 day · 7 hour ·
//   8 minute · 9 second
// Flags: bits 0 and 4 the unit (neither kg, bit 0 lb, bit 4 jin, both
// stone); bit 5 set and bit 7 clear = a stabilised live reading, anything
// else is still settling and is ignored.
//
// Weight = raw/200 kg, raw/100 lb, raw/100 jin (half a kilogram each),
// raw/100 stone. Raw 0xFFF0 is the overload marker, never a weight.
//
// STORED HISTORY (both scales) — on [kMiScaleHistoryChar], notify + write:
//   host  `01 <user id u32 LE>`   how many records for this user
//   scale `01 <count u16 LE>`
//   host  `02`                    send them (skipped when count is 0)
//   scale records: 10-byte Scale 2 records, or 13-byte frames laid out as
//         0x2A9C on the composition scale; a notification of one byte or
//         less ends them
//   host  `03`                    stop; sent at the end of every session
// `04 <user id u32 LE>` acknowledges the transfer and makes the scale DELETE
// those records. Nothing here builds it: without it the scale keeps its
// history and re-sends it next time, which a timestamp-keyed upsert absorbs.
//
// TIMESTAMPS ARE UTC wall-clock components: the scale's clock is set in UTC
// ([miScaleClockValue]) and its stamps are read back the same way.

import 'health_thermometer.dart' show WallClock, gattDateTime;

const String kMiScaleBodyCompositionService =
    '0000181b-0000-1000-8000-00805f9b34fb';
const String kMiScaleBodyCompositionChar =
    '00002a9c-0000-1000-8000-00805f9b34fb';
const String kMiScaleWeightService = '0000181d-0000-1000-8000-00805f9b34fb';
const String kMiScaleWeightChar = '00002a9d-0000-1000-8000-00805f9b34fb';

/// Stored-history characteristic on both scales (notify + write).
const String kMiScaleHistoryChar = '00002a2f-0000-3512-2118-0009af100700';

/// Scale mode (read + write, u16 LE). A scale reporting mode 3 is switched
/// to user mode with [miScaleUserModeCommand] on connect.
const String kMiScaleModeChar = '00001542-0000-3512-2118-0009af100700';

class MiScaleReading {
  final double kg;
  final WallClock? at;

  /// Bio-impedance in ohms (body composition scale only; null otherwise).
  final int? impedanceOhm;
  const MiScaleReading(this.kg, this.at, this.impedanceOhm);
}

/// Raw weight the scales send when the load is beyond their range.
const int _kOverload = 0xFFF0;

/// Smart Scale 2 weight: the unit is flags bits 0 and 4 together.
double _scale2Kg(int raw, int flags) => switch (flags & 0x11) {
      0x01 => raw / 100 * 0.45359237,
      0x10 => raw / 100 * 0.5,
      0x11 => raw / 100 * 6.35029318,
      _ => raw / 200,
    };

/// One body-composition frame (live, or one 13-byte history record), or null
/// if the weight is overloaded, malformed, or (live only) not yet stable.
/// A [stored] record carries no live stability state, so it is not filtered
/// on it; only its zero weight is skipped. Impedance is set only on an
/// impedance-stable frame with a real value.
MiScaleReading? parseMiBodyComposition(List<int> b, {bool stored = false}) {
  if (b.length < 13 || (!stored && b[1] & 0x20 == 0)) return null;
  final raw = b[11] | (b[12] << 8);
  if (raw == _kOverload || (stored && raw == 0)) return null;
  final kg = b[0] & 0x01 != 0
      ? raw / 100 * 0.45359237
      : b[1] & 0x40 != 0
          ? raw / 100 * 0.5
          : raw / 200;
  final impedance = b[9] | (b[10] << 8);
  return MiScaleReading(
    kg,
    gattDateTime(b, 2),
    b[1] & 0x02 != 0 && impedance != 0 && impedance < 65533 ? impedance : null,
  );
}

/// Every 13-byte record in one composition-scale history notification. No
/// stability filter: see [parseMiBodyComposition]'s `stored`.
List<MiScaleReading> parseMiBodyCompositionRecords(List<int> b) => [
      for (var i = 0; i + 13 <= b.length; i += 13)
        if (parseMiBodyComposition(b.sublist(i, i + 13), stored: true)
            case final r?)
          r,
    ];

/// Every stabilised 10-byte record in one live Smart Scale 2 notification.
/// An unstabilised or overloaded record is skipped, not the ones after it.
List<MiScaleReading> parseMiScale2Records(List<int> b) {
  final out = <MiScaleReading>[];
  for (var i = 0; i + 10 <= b.length; i += 10) {
    final flags = b[i], raw = b[i + 1] | (b[i + 2] << 8);
    if (flags & 0x20 == 0 || flags & 0x80 != 0 || raw == _kOverload) continue;
    out.add(
        MiScaleReading(_scale2Kg(raw, flags), gattDateTime(b, i + 3), null));
  }
  return out;
}

/// Every stored record in one Smart Scale 2 history notification. Stored
/// records carry no live stability state: only a record with no flags at
/// all, a zero weight (written at a reboot) or the overload marker is
/// skipped.
List<MiScaleReading> parseMiScale2History(List<int> b) {
  final out = <MiScaleReading>[];
  for (var i = 0; i + 10 <= b.length; i += 10) {
    final flags = b[i], raw = b[i + 1] | (b[i + 2] << 8);
    if (flags == 0 || raw == 0 || raw == _kOverload) continue;
    out.add(
        MiScaleReading(_scale2Kg(raw, flags), gattDateTime(b, i + 3), null));
  }
  return out;
}

/// History: how many records the scale holds for [userId] (u32 LE).
List<int> miScaleHistoryRequest(int userId) => [
      0x01,
      userId & 0xff,
      (userId >> 8) & 0xff,
      (userId >> 16) & 0xff,
      (userId >> 24) & 0xff,
    ];

/// The record count in the scale's `01 <count u16 LE>` answer, or null.
int? miScaleHistoryCount(List<int> b) =>
    b.length == 3 && b[0] == 0x01 ? b[1] | (b[2] << 8) : null;

const List<int> kMiScaleHistorySend = [0x02];

/// Ends a history session. Not an acknowledgement: the records stay.
const List<int> kMiScaleHistoryStop = [0x03];

/// A notification of one byte or less ends the scale's history records.
bool miScaleHistoryDone(List<int> b) => b.length <= 1;

/// The user-mode command for a scale whose [kMiScaleModeChar] reads 3.
List<int> miScaleUserModeCommand({required bool composition}) =>
    composition
        ? const [0x06, 0x0B, 0x00, 0x00]
        : const [0x03, 0x01, 0x00, 0x00, 0x00];

/// The scales' Current Time (0x2A2B) value for [utc]: date-time, day of week
/// (1 = Sunday … 7 = Saturday), then two zero bytes.
List<int> miScaleClockValue(DateTime utc) => [
      utc.year & 0xff,
      utc.year >> 8,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
      utc.weekday % 7 + 1,
      0,
      0,
    ];
