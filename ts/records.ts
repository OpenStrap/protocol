export interface R24 {
  ts_epoch: number;
  ts_subsec: number;
  counter: number;
  hr: number;
  spo2: number;
  skin_temp_c: number;
  resting_hr: number;
  accel_g: [number, number, number];
  raw_tail: string;
}

/**
 * Port of whoop.py:parse_r24.
 * Decodes a Type-24 historical data record (96 bytes).
 */
export function parse_r24(inner: Uint8Array): R24 | null {
  // RE §5: Guard: if inner length < 89, return null.
  if (inner.length < 89) {
    return null;
  }

  const view = new DataView(inner.buffer, inner.byteOffset, inner.byteLength);

  // Helper for rounding to match whoop.py's round()
  const round = (v: number, decimals: number = 0) => {
    const p = Math.pow(10, decimals);
    return Math.round(v * p) / p;
  };

  return {
    // RE §5: u32 UNIX timestamp (seconds) @ [7:11]
    ts_epoch: view.getUint32(7, true),
    // RE §5: u16 sub-seconds @ [11:13]
    ts_subsec: view.getUint16(11, true),
    // RE §5: u32 record counter (+1/rec) @ [3:7]
    counter: view.getUint32(3, true),
    // RE §5: heart rate (bpm) @ [17]
    hr: inner[17],
    // RE §5: SpO2 (%) @ [72]
    spo2: inner[72],
    // RE §5: skin temp (°C = [70]/4) @ [70]
    skin_temp_c: round(inner[70] / 4.0, 2),
    // RE §5: resting/baseline HR @ [88]
    resting_hr: inner[88],
    // RE §5: tri-axial accel (g) float32 x3 @ [36:48]
    accel_g: [
      round(view.getFloat32(36, true), 4),
      round(view.getFloat32(40, true), 4),
      round(view.getFloat32(44, true), 4),
    ],
    // RE §5: app-opaque payload [13:]
    raw_tail: Array.from(inner.slice(13))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join(""),
  };
}
