// Amazfit Scale ("Amazfit Scale"). Plain GATT on service FEE0, no auth.
//
// CLOCK — char 0x0019, write: the same 10 bytes as the Mi scales' Current
// Time ([miScaleClockValue]): year u16 LE, month, day, hour, minute, second,
// day of week (1 = Sunday), 0, 0.
//
// MEASUREMENT — char 0x0021, notify. 20-byte records, little-endian, several
// may share one notification; every field is always present (a flag only
// says whether it holds a value):
//   0-1   flags
//   2-6   time, packed (UTC): year bits 0-12, month 13-16, day 17-21,
//         hour 22-27, minute 28-33, second 34-39
//   7-8   weight raw (flag 0x0008); 0xFFFF = overload
//   9-11  impedance (flag 0x0010; unit not established, not decoded)
//   12    heart rate (flag 0x0020; not decoded)
//   13    pressure (flag 0x0040; not decoded)
//   14-19 family id (flag 0x0080)
// Flags: unit = bit 0 | bit 14 (0 kg, raw/200; otherwise raw/100: bit 0 lb,
// bit 14 jin, both = a stone display whose raw value is still pounds);
// bits 9-10 measurement state (0 measuring, 1 done, 2 failed).
//
// HISTORY lives on char 00000018-...-0009af100700 and is acknowledged with a
// `04` command that is presumed to delete it on the scale. Nothing here
// builds any of it.

import 'health_thermometer.dart' show WallClock;

/// The scale's service.
const String kAmazfitScaleService = '0000fee0-0000-1000-8000-00805f9b34fb';

/// Clock (write), see the header.
const String kAmazfitScaleClockChar = '00000019-0000-1000-8000-00805f9b34fb';

/// Live measurement records (notify), see the header.
const String kAmazfitScaleMeasureChar = '00000021-0000-1000-8000-00805f9b34fb';

/// One finished weighing.
class AmazfitScaleReading {
  final double kg;

  /// UTC wall-clock components as the scale stamped them; null when they
  /// are not a real date.
  final WallClock? at;
  const AmazfitScaleReading(this.kg, this.at);
}

/// Every finished weighing in one measurement notification. A record that
/// is still measuring, failed, has no weight, or is overloaded is skipped,
/// not the ones after it.
List<AmazfitScaleReading> parseAmazfitScaleRecords(List<int> b) {
  final out = <AmazfitScaleReading>[];
  for (var i = 0; i + 20 <= b.length; i += 20) {
    final flags = b[i] | (b[i + 1] << 8);
    final raw = b[i + 7] | (b[i + 8] << 8);
    if (flags & 0x0008 == 0 || (flags >> 9) & 0x3 != 1 || raw == 0xFFFF) {
      continue;
    }
    final unit = (flags & 0x0001) | ((flags & 0x4000) >> 10);
    final kg = switch (unit) {
      0 => raw / 200,
      16 => raw / 100 * 0.5,
      _ => raw / 100 * 0.45359237,
    };
    final lo = b[i + 2] | (b[i + 3] << 8) | (b[i + 4] << 16) | (b[i + 5] << 24);
    final hi = b[i + 6];
    final year = lo & 0x1FFF, month = (lo >> 13) & 0xF, day = (lo >> 17) & 0x1F;
    final hour = (lo >> 22) & 0x3F;
    final minute = ((lo >> 28) & 0xF) | ((hi & 0x3) << 4);
    final second = hi >> 2;
    final valid = year >= 2000 &&
        month >= 1 &&
        month <= 12 &&
        day >= 1 &&
        day <= DateTime.utc(year, month + 1, 0).day &&
        hour < 24 &&
        minute < 60 &&
        second < 60;
    out.add(AmazfitScaleReading(
        kg,
        valid
            ? (
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second,
              )
            : null));
  }
  return out;
}
