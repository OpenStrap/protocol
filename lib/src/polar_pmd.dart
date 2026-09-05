// Polar's PMD (measurement data) service, PPI stream only — plain functions,
// no crypto, no key exchange. Any Polar optical sensor that exposes this GATT
// service (armband, ring, chest strap).
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one and
// `flutter_blue_plus` has no simulator path, so this is verified by the wire
// layout and by the compiler.
//
// PPI ONLY. The service also carries ECG, PPG, accelerometer and gyroscope
// streams under the same control point and data characteristic; none of them
// are decoded here; there is no decoder to run over their bytes. PPI needs no
// settings negotiation and is never compressed, which is what makes it the one
// stream worth decoding without a settings-block parser or a per-type
// reassembler.

/// Control-point request opcodes (first byte of a control-point write).
const int kPolarPmdOpGetMeasurementSettings = 0x01;
const int kPolarPmdOpRequestMeasurementStart = 0x02;
const int kPolarPmdOpStopMeasurement = 0x03;

/// Measurement-type byte. Low 6 bits of a data frame's first byte carry the
/// same value.
const int kPolarPmdMeasTypePpi = 0x03;

/// First byte of every control-point INDICATE reply.
const int kPolarPmdControlPointResponseCode = 0xF0;

/// The bytes to write to the control point to start online PPI streaming.
/// `(recording << 7) | measType` with `recording` clear (online streaming, not
/// on-sensor recording) and no setting blocks — PPI has none to negotiate.
List<int> polarPmdStartPpi() =>
    const [kPolarPmdOpRequestMeasurementStart, kPolarPmdMeasTypePpi];

/// The bytes to write to the control point to stop the PPI stream.
List<int> polarPmdStopPpi() =>
    const [kPolarPmdOpStopMeasurement, kPolarPmdMeasTypePpi];

/// One control-point indicate reply: `[0xF0, reqOpcode, measType, status, …]`.
class PolarPmdControlResponse {
  final int reqOpcode;
  final int measType;

  /// 0 is success. Anything else is a refusal — this file names no other
  /// codes because nothing downstream branches on which one it was.
  final int status;

  const PolarPmdControlResponse({
    required this.reqOpcode,
    required this.measType,
    required this.status,
  });

  bool get ok => status == 0;
}

/// Parse one control-point notification. Null when it is too short or does
/// not carry the `0xF0` response marker — a malformed reply is dropped, never
/// read as a success.
PolarPmdControlResponse? parsePolarPmdControlResponse(List<int> value) {
  if (value.length < 4) return null;
  if (value[0] != kPolarPmdControlPointResponseCode) return null;
  return PolarPmdControlResponse(
    reqOpcode: value[1],
    measType: value[2],
    status: value[3],
  );
}

/// One Pulse-to-Pulse Interval record.
class PolarPpiSample {
  /// Beats per minute, or 0 when the sensor found no valid beat this record —
  /// a refusal, never a measurement (see [parsePolarPmdPpiFrame]'s caller).
  final int hr;

  /// The beat-to-beat interval, in milliseconds.
  final int ppiMs;

  /// The sensor's own error estimate for [ppiMs], in milliseconds.
  final int errorEstimateMs;

  /// Flags byte, bit 0. Documented as marking a reading that should be
  /// dropped from an HRV computation (a "blocker" sample), but — like
  /// [skinContactBits] below — this comes from the same never-tested flags
  /// byte, so which bit is blocker is NOT independently confirmed against
  /// hardware.
  final bool blocker;

  /// Flags byte, bits 1-2, verbatim. These are documented as carrying
  /// skin-contact information, but which value means contact and which means
  /// none is NOT independently confirmed against hardware — captured under
  /// its own name rather than gated on.
  final int skinContactBits;

  const PolarPpiSample({
    required this.hr,
    required this.ppiMs,
    required this.errorEstimateMs,
    required this.blocker,
    required this.skinContactBits,
  });
}

/// Parse one PMD data-characteristic notification as a PPI frame.
///
/// Layout: byte 0 measurement type (low 6 bits); bytes 1-8 a u64 LE PMD
/// timestamp (unused here — PPI carries no clock this decoder needs, see
/// [PolarPpiSample]'s field list); byte 9 frame type (bit 7 = compressed);
/// bytes 10+ one or more fixed 6-byte PPI records:
/// `[hr][ppiMs u16 LE][errorEstimateMs u16 LE][flags]`.
///
/// Returns null when the frame is too short, is not measurement type PPI, is
/// flagged compressed (PPI is never compressed — a compressed bit here means
/// this is not the shape this decoder expects), or its body is not a whole
/// number of 6-byte records. A malformed frame is dropped, never patched up
/// into a plausible-looking beat.
List<PolarPpiSample>? parsePolarPmdPpiFrame(List<int> value) {
  if (value.length < 10) return null;
  if ((value[0] & 0x3F) != kPolarPmdMeasTypePpi) return null;
  if ((value[9] & 0x80) != 0) return null;
  final bodyLen = value.length - 10;
  if (bodyLen == 0 || bodyLen % 6 != 0) return null;
  final out = <PolarPpiSample>[];
  for (var i = 10; i + 6 <= value.length; i += 6) {
    final flags = value[i + 5];
    out.add(PolarPpiSample(
      hr: value[i],
      ppiMs: value[i + 1] | (value[i + 2] << 8),
      errorEstimateMs: value[i + 3] | (value[i + 4] << 8),
      blocker: (flags & 0x01) != 0,
      skinContactBits: (flags >> 1) & 0x03,
    ));
  }
  return out;
}
