// The Bluetooth SIG Health Thermometer profile (service 0x1809) and the
// Current Time characteristic (0x2A2B) — standard GATT, so this decoder works
// for any compliant thermometer, the Femometer Vinca 2 basal thermometer
// included.
//
// Temperature Measurement (0x2A1C), indicated:
//   flags u8 — bit 0: Fahrenheit (else Celsius) · bit 1: timestamp present ·
//              bit 2: temperature type present
//   value    — IEEE-11073 32-bit FLOAT: 24-bit signed mantissa + 8-bit
//              signed base-10 exponent, little-endian
//   [timestamp] 7 bytes — year u16 LE, month, day, hour, minute, second
//   [type]   u8 — measurement site
//
// TIMESTAMPS ARE THE DEVICE'S LOCAL WALL CLOCK, carried here as components,
// never as an epoch: the host resolves them against its own local calendar.

/// GATT UUIDs (128-bit form of the SIG 16-bit ids).
const String kHtpService = '00001809-0000-1000-8000-00805f9b34fb';
const String kHtpTemperatureMeasurement =
    '00002a1c-0000-1000-8000-00805f9b34fb';
const String kHtpMeasurementInterval = '00002a21-0000-1000-8000-00805f9b34fb';
const String kCurrentTimeChar = '00002a2b-0000-1000-8000-00805f9b34fb';

/// An IEEE-11073 32-bit FLOAT, or null for its reserved NaN / NRes / ±INF
/// mantissas.
double? ieee11073Float32(List<int> b, int offset) {
  if (offset + 4 > b.length) return null;
  var mantissa = b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16);
  if (mantissa >= 0x7ffffe && mantissa <= 0x800002) return null;
  if (mantissa & 0x800000 != 0) mantissa -= 0x1000000;
  final exponent = b[offset + 3] >= 0x80 ? b[offset + 3] - 0x100 : b[offset + 3];
  var v = mantissa.toDouble();
  if (exponent >= 0) {
    for (var i = 0; i < exponent; i++) {
      v *= 10;
    }
  } else {
    for (var i = 0; i < -exponent; i++) {
      v /= 10;
    }
  }
  return v;
}

/// Local wall-clock components as the device sent them.
typedef WallClock = ({int year, int month, int day, int hour, int minute, int second});

/// A standard 7-byte date-time (year u16 LE, month, day, hour, min, sec), or
/// null when it is the "unknown" pattern (year 0 / month 0 / day 0) or out of
/// range — a day the month does not have (Feb 31) included, since building a
/// `DateTime` from it would silently roll over into the next month.
WallClock? gattDateTime(List<int> b, int offset) {
  if (offset + 7 > b.length) return null;
  final year = b[offset] | (b[offset + 1] << 8);
  final month = b[offset + 2], day = b[offset + 3];
  final hour = b[offset + 4], minute = b[offset + 5], second = b[offset + 6];
  if (year < 1582 || year > 9999 || month < 1 || month > 12 || day < 1) {
    return null;
  }
  if (day > DateTime.utc(year, month + 1, 0).day) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  return (
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    second: second,
  );
}

class HtpMeasurement {
  /// Always Celsius — a Fahrenheit reading is converted.
  final double celsius;
  final WallClock? at;
  final int? site;
  const HtpMeasurement(this.celsius, this.at, this.site);
}

/// Decodes one Temperature Measurement value, or null when it is malformed
/// or carries a reserved (non-numeric) value. A field the flags declare but
/// the value does not carry is a truncated measurement and refuses the whole
/// value: a stored reading whose 7-byte stamp was cut off would otherwise
/// land at arrival time, which for a synced reading is the wrong day.
HtpMeasurement? parseHtpMeasurement(List<int> b) {
  if (b.length < 5) return null;
  final flags = b[0];
  final raw = ieee11073Float32(b, 1);
  if (raw == null) return null;
  final celsius = flags & 0x01 != 0 ? (raw - 32) * 5 / 9 : raw;
  var i = 5;
  WallClock? at;
  if (flags & 0x02 != 0) {
    if (i + 7 > b.length) return null;
    at = gattDateTime(b, i);
    i += 7;
  }
  int? site;
  if (flags & 0x04 != 0) {
    if (i >= b.length) return null;
    site = b[i];
  }
  return HtpMeasurement(celsius, at, site);
}

/// A Current Time (0x2A2B) value for [local]: date-time, day of week
/// (1 = Monday), fractions of a second in 1/256, adjust reason 0.
List<int> currentTimeValue(DateTime local) => [
      local.year & 0xff,
      local.year >> 8,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
      local.weekday,
      local.millisecond * 256 ~/ 1000,
      0,
    ];
