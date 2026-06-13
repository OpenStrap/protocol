export interface R24 {
  ts_epoch: number;
  ts_subsec: number;
  counter: number;
  hr: number;
  /** Beat-to-beat (R-R) intervals in ms for this 1 s record, 0–4 of them.
   *  Validated on 127,971 records: 99.7% fall in 300–2000 ms. The HRV source. */
  rr_count: number;
  rr_intervals_ms: number[];
  /** Raw green-LED PPG ADC count. Pulsatile; not a finished value. */
  ppg_green: number;
  /** Gravity/accel vector (g), 3× float32. |g| ≈ 1.0 at rest (corpus mean 1.012). */
  accel_g: [number, number, number];
  /** Raw red-channel ADC. RELATIVE only — SpO₂ % is computed in WHOOP's cloud, not sent. */
  spo2_red_raw: number;
  /** Raw skin-temperature ADC. RELATIVE only — °C is computed server-side, never sent. */
  skin_temp_raw: number;
  /** Untouched payload [13:] — kept so records can be re-decoded as the map improves. */
  raw_tail: string;
}

/**
 * Decode a Type-24 historical biometric record (96 bytes, 1 Hz).
 *
 * Offsets verified against 127,971 of our own stored records and cross-checked
 * with an independent implementation (johnmiddleton12/wearable). Only fields
 * that survived that validation are surfaced. The bytes previously read as
 * `spo2` and `skin_temp_c` were misidentified (LED-drive current and ambient
 * light) and are gone. Raw ADC fields are RELATIVE: the band relays them
 * uncalibrated and WHOOP derives SpO₂/°C in its cloud.
 */
export function parse_r24(inner: Uint8Array): R24 | null {
  if (inner.length < 89) {
    return null;
  }

  const view = new DataView(inner.buffer, inner.byteOffset, inner.byteLength);
  const round = (v: number, decimals: number = 0) => {
    const p = Math.pow(10, decimals);
    return Math.round(v * p) / p;
  };

  // R-R intervals: rr_count @ [18], then rr_count signed int16 LE from [19].
  const rr_count = inner[18];
  const rr_intervals_ms: number[] = [];
  for (let i = 0; i < rr_count && 19 + 2 * i + 2 <= inner.length; i++) {
    const v = view.getInt16(19 + 2 * i, true);
    if (v > 0) rr_intervals_ms.push(v);
  }

  return {
    ts_epoch: view.getUint32(7, true),     // unix seconds @ [7:11]
    ts_subsec: view.getUint16(11, true),   // sub-seconds @ [11:13]
    counter: view.getUint32(3, true),      // record counter (+1/rec) @ [3:7]
    hr: inner[17],                         // heart rate bpm @ [17] (0 = no reading)
    rr_count,
    rr_intervals_ms,
    ppg_green: view.getUint16(29, true),   // raw green PPG ADC @ [29]
    accel_g: [                             // gravity/accel (g) float32 ×3 @ [36:48]
      round(view.getFloat32(36, true), 4),
      round(view.getFloat32(40, true), 4),
      round(view.getFloat32(44, true), 4),
    ],
    spo2_red_raw: view.getUint16(64, true),    // raw red ADC @ [64] (relative)
    skin_temp_raw: view.getUint16(68, true),   // raw temp ADC @ [68] (relative)
    raw_tail: Array.from(inner.slice(13))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join(""),
  };
}
