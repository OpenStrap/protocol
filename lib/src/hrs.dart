// The Bluetooth SIG's Heart Rate Service (0x180D) — Heart Rate Measurement
// (0x2A37) — as a pure function. Any standard chest strap or optical armband
// that implements the SIG spec, not any one vendor's device.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a strap and
// `flutter_blue_plus` has no simulator path, so this is verified by the
// Bluetooth SIG's Heart Rate Service 1.0 layout and by the compiler.

/// One Heart Rate Measurement notification.
class HrsSample {
  /// Beats per minute as the sensor reported it.
  final int hr;

  /// Beat-to-beat DURATIONS in milliseconds carried by this notification, in
  /// the order the sensor sent them. Empty when the sensor does not report RR
  /// (the flag is OPTIONAL in the SIG spec and plenty of straps send only a
  /// bpm) — empty is "not reported", never "zero".
  final List<int> rrMs;

  /// The sensor's own contact claim: true/false when it reports one, null when
  /// it does not support the field at all. Never inferred from HR.
  final bool? contact;

  const HrsSample({required this.hr, required this.rrMs, this.contact});
}

/// Parse a Heart Rate Measurement (0x2A37) value.
///
/// Layout (Bluetooth SIG, Heart Rate Service 1.0):
///   byte 0  flags
///     bit 0  HR format: 0 = uint8, 1 = uint16 little-endian
///     bits 1-2  sensor contact: 0b00/0b01 = not supported, 0b10 = no contact,
///               0b11 = contact
///     bit 3  Energy Expended present (uint16, kJ) — skipped, we do not use it
///     bit 4  RR-Interval present (one or more uint16, units of 1/1024 s)
///   then HR, then energy expended if present, then RR intervals to the end.
///
/// Returns null for a value that cannot be read as this characteristic (too
/// short, or a truncated field). A malformed notification is DROPPED, never
/// patched up into a plausible-looking beat.
HrsSample? parseHeartRateMeasurement(List<int> value) {
  if (value.length < 2) return null;
  final flags = value[0];
  final wide = (flags & 0x01) != 0;
  var i = 1;
  final int hr;
  if (wide) {
    if (value.length < 3) return null;
    hr = value[1] | (value[2] << 8);
    i = 3;
  } else {
    hr = value[1];
    i = 2;
  }
  // 0 bpm is not a measurement. Sensors emit it while searching for a signal;
  // storing it would put a real-looking zero into a heart-rate series.
  if (hr <= 0 || hr > 300) return null;

  final contactBits = (flags >> 1) & 0x03;
  final contact = contactBits < 2 ? null : contactBits == 3;

  // Energy Expended is a fixed 2-byte field ONCE the flag says it is present
  // — a notification that sets the bit but doesn't carry both bytes is
  // truncated, not "the field happens to be shorter here", so it is refused
  // outright rather than silently walked past.
  if ((flags & 0x08) != 0) {
    if (i + 2 > value.length) return null;
    i += 2; // energy expended — present, not used
  }
  final rr = <int>[];
  if ((flags & 0x10) != 0) {
    // Trailing RR intervals, uint16 LE, 1/1024 s each. An ODD remainder means
    // the buffer ends mid-field — every earlier field's offset is only as
    // trustworthy as the notification's own declared length, so a short tail
    // refuses the whole notification instead of quietly keeping what parsed.
    if ((value.length - i).isOdd) return null;
    while (i + 1 < value.length) {
      final ticks = value[i] | (value[i + 1] << 8);
      i += 2;
      // 1024 ticks = 1 s. Round to the nearest millisecond.
      final ms = (ticks * 1000 + 512) ~/ 1024;
      // 250-3000 ms is 20-240 bpm. Outside that the value is not a beat
      // interval, and a chest strap emits exactly this junk on a dropped beat.
      if (ms >= 250 && ms <= 3000) rr.add(ms);
    }
  }
  return HrsSample(hr: hr, rrMs: rr, contact: contact);
}
