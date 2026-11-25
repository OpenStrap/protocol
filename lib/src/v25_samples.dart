// v25_samples.dart — the optical samples of a WHOOP 4 v25 historical record.
//
// Same encoding as gen5's v26 window: an i32 first sample @ inner[15:19], then
// 24 saturating i16 deltas @ inner[19:67], 25 samples in all. So this reuses
// [reconstructSaturatedDeltaWindow] and its evidence about the tail.
//
// How it was checked (one WHOOP 4.0, firmware harvard 41.17.6.0, realtime raw
// stream on): 739 v25 records have an R11 frame with the same timestamp. In
// 734 the 25 samples equal R11 slot 1 lane A samples 0, 2, ..., 48 exactly. The
// other five hold 24 differing deltas, every one the live difference clamped
// to the i16 range, and every one a rail value. So all records without a rail
// delta matched, and all five records with one did not. A rail delta is
// ambiguous (the true difference may be larger), so the sample it reaches and
// every later absolute value in that record are not trustworthy. The next
// record starts from its own absolute value.
// Which LED/photodiode slot 1 lane A is, is not established.

import 'dart:typed_data';

import 'constants.dart';
import 'gen5_records.dart'
    show Gen5PpgReconstruction, reconstructSaturatedDeltaWindow;

/// Samples of one v25 record (~26 Hz), or null when [inner] is not a v25
/// historical record of at least 67 bytes. Decode each record on its own: the
/// first sample is absolute, never carry a sum across records. Use
/// [Gen5PpgReconstruction.trustedSamples]; do not trust the tail after a rail delta.
Gen5PpgReconstruction? reconstructV25Samples(Uint8List inner) {
  if (inner.length < 67 ||
      inner[0] != PacketType.historicalData ||
      inner[1] != 25) {
    return null;
  }
  final view = ByteData.sublistView(inner);
  return reconstructSaturatedDeltaWindow(view.getInt32(15, Endian.little), [
    for (var k = 0; k < 24; k++) view.getInt16(19 + 2 * k, Endian.little),
  ]);
}
