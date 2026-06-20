export interface R24 {
  ts_epoch: number;
  ts_subsec: number;
  counter: number;
  hr: number;
  /** Beat-to-beat (R-R) intervals in ms for this 1 s record, 0–4 of them.
   *  Validated on 127,971 records: 99.7% fall in 300–2000 ms. The HRV source. */
  rr_count: number;
  rr_intervals_ms: number[];
  /** Raw green-LED PPG ADC count @ [29]. Pulsatile; not a finished value. */
  ppg_green: number;
  /** Raw red/IR-LED PPG ADC count @ [31]. 2nd PPG channel; pulsatile, full dynamic range.
   *  Validated on 261 R2 records over 113 h (108 distinct, 195–61695). RELATIVE. */
  ppg_red_ir: number;
  /** Gravity/accel vector (g), 3× float32 @ [36:48]. |g| ≈ 1.0 at rest (corpus mean 1.012).
   *  Note: a second f32 triplet at [52:64] is byte-identical to this across all 811
   *  validation records (a firmware-mirrored copy, not an independent sensor) — so it
   *  is deliberately NOT surfaced. */
  accel_g: [number, number, number];
  /** Skin-contact quality @ [51] (u8, 0–198). Varies with optical coupling.
   *  NOT a clean on/off-wrist flag — zero rows still carry valid HR; wear is the
   *  WRIST_ON/OFF events. Surface as contact quality only. */
  skin_contact: number;
  /** Raw red-channel ADC @ [64]. RELATIVE only — SpO₂ % is computed in WHOOP's cloud, not sent. */
  spo2_red_raw: number;
  /** Raw IR-channel ADC @ [66]. RELATIVE only. Pairs with spo2_red_raw → the red/IR ratio
   *  that an SpO₂ estimate needs (we previously kept only the red channel). */
  spo2_ir_raw: number;
  /** Raw skin-temperature ADC @ [68]. RELATIVE only — °C is computed server-side, never sent. */
  skin_temp_raw: number;
  /** Raw ambient-light ADC @ [70]. RELATIVE. Used to background-correct the PPG/SpO₂ channels. */
  ambient_raw: number;
  /** Untouched payload [13:] — kept so records can be re-decoded as the map improves. */
  raw_tail: string;
}

/**
 * Decode a Type-24 historical biometric record (96 bytes, 1 Hz).
 *
 * Offsets verified against 127,971 of our own stored records and cross-checked
 * with two independent implementations (contributor/wearable; reference implementation
 * whoop_protocol.json V24). Only fields that survived per-byte variance
 * validation on real data are surfaced. The optical block (ppg_red_ir@31,
 * spo2_ir@66, ambient@70) and skin_contact@51 were added after confirming they
 * VARY across 261 R2 records spanning 113 h (plus 550 golden capture records).
 * The f32 triplet at @52 is dropped: byte-identical to accel_g@36 on all 811
 * records (a mirrored copy). Conversely the reference labels `resp_rate_raw`@76
 * and `signal_quality`@78 are NOT decoded: both are bit-constant (3073 / 3074)
 * across all 811 records — a fixed trailer on our firmware, not a measurement
 * (WHOOP derives respiration in-cloud from PPG; see backend resp.ts). Raw ADC
 * fields are RELATIVE: the band relays them uncalibrated and WHOOP derives
 * SpO₂/°C in its cloud.
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
    ppg_red_ir: view.getUint16(31, true),  // raw red/IR PPG ADC @ [31]
    accel_g: [                             // gravity/accel (g) float32 ×3 @ [36:48]
      round(view.getFloat32(36, true), 4),
      round(view.getFloat32(40, true), 4),
      round(view.getFloat32(44, true), 4),
    ],
    skin_contact: inner[51],               // contact-quality u8 @ [51] (0–198, NOT a wear flag)
    spo2_red_raw: view.getUint16(64, true),    // raw red ADC @ [64] (relative)
    spo2_ir_raw: view.getUint16(66, true),     // raw IR ADC @ [66] (relative)
    skin_temp_raw: view.getUint16(68, true),   // raw temp ADC @ [68] (relative)
    ambient_raw: view.getUint16(70, true),     // raw ambient-light ADC @ [70] (relative)
    raw_tail: Array.from(inner.slice(13))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join(""),
  };
}
