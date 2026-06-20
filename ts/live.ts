// live.ts — verified WHOOP record decoders for the live + IMU frame types, mirroring
// the reference client / PROTOCOL.md. Companion to records.ts (parse_r24): records.ts
// owns the Type-24 historical substrate; this owns the live/compact + IMU frames.
// All byte-offset knowledge for the band lives in this package (openstrap-protocol);
// the backend is pure orchestration and calls in here to decode.
//
// Each decoded record emits a DecodedSample:
//   { ts, hr, activity, steps_inc, wrist_on, rec_type }
// where `activity` is the actigraphy signal = stddev of |accel(g)| over the
// 100-sample IMU window (R10 only; 0 for HR-only records).
//
// Offsets (PROTOCOL.md):
//   R10  (rec_type 10, pkt 0x2F live/0x2B): ts@7, hr@17, counter@3,
//        accel arrays @85/285/485, gyro @688/888/1088, scale ÷4096 (4096 LSB/g).
//   0x28 (live compact HR): ts@2 (u32 LE), hr@8 (u8), wrist via hr>0.
//   0x2B: same layout as R10 (live R10).
//   R24  (rec_type 24): header ts@7, counter@3; spo2@72, skin_temp@70/4, resting_hr@88 (RELATIVE-only, not surfaced here).
//   0x33: live IMU stream — RAW-ONLY, no sample emitted (low decode confidence).
//
// RR/HRV: the historical source is R24 (records.ts, rr_count@18 / rr@19). Live RR is
// also carried by the compact-HR (0x28) and R10 records — see realtimeRr() below.
// The separate "type-17 / Labrador" RR record (count@24/rr@26 in our Python probe) is
// NOT shipped: an independent implementation (reference implementation) has no such record type and
// reads live RR from 0x28/R10 instead, so our type-17 offsets are uncorroborated. RR
// unit is raw u16 ms (confirmed across both implementations); callers MUST physiologically
// gate (300–2000 ms) so an unvalidated offset yields droppable garbage, never corruption.

import { parse_r24 } from './records'

export interface DecodedSample {
  ts: number          // unix seconds
  hr: number          // bpm (0 = off-wrist / no reading)
  activity: number    // motion magnitude (stddev of |accel(g)|), 0 if no IMU
  steps_inc: number   // steps detected in this record's IMU window (R10 only)
  wrist_on: boolean   // worn proxy (hr>0; authoritative wear is WRIST_ON/OFF events)
  rec_type: number    // 10 | 24 | 28
}

export const hexToBytes = (hex: string): Uint8Array =>
  new Uint8Array(hex.trim().match(/.{1,2}/g)!.map((b) => parseInt(b, 16)))

/** One IMU frame's accel as ordered magnitude samples (g) + its time + sub-order. */
export interface ImuFrame { ts: number; idx: number; mags: number[] }

// frameAccel — decode one IMU frame's accelerometer into ordered |accel|(g)
// samples. Handles BOTH channels the strap streams:
//   • 0x33 live IMU stream — ts@4, sub-frame idx@14, 10 accel samples
//     (X[0:10],Y[10:20],Z[20:30]) from offset 24, scale 1/4096.
//   • R10 (rec 0x0A) — ts@7, 100 accel samples @85/285/485, scale 1/4096.
// Returns null if it isn't an accel-bearing frame. Used by the backend steps
// runner (steps_imu.ts) to rebuild the signal for the AN-2554 pedometer that
// lives in openstrap-analytics (calcSteps). Kept here with the other IMU
// decoders (see r10Motion) so all byte-offset knowledge stays in one place.
export function frameAccel(hex: string): ImuFrame | null {
  let b: Uint8Array
  try { b = hexToBytes(hex) } catch { return null }
  if (b.length < 32) return null
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength)
  const pkt = b[0], rec = b[1]
  // 0x33 IMU stream: 10 accel samples (X,Y,Z) from offset 24.
  if (pkt === 0x33 && b.length >= 84) {
    const ts = view.getUint32(4, true)
    const idx = view.getUint16(14, true)
    const mags: number[] = []
    for (let i = 0; i < 10; i++) {
      const x = view.getInt16(24 + 2 * i, true)
      const y = view.getInt16(24 + 2 * (10 + i), true)
      const z = view.getInt16(24 + 2 * (20 + i), true)
      mags.push(Math.sqrt(x * x + y * y + z * z) / 4096)
    }
    return ts > 0 ? { ts, idx, mags } : null
  }
  // R10: rec 0x0A, ts@7, accel X@85/Y@285/Z@485 (100 int16 each).
  if (rec === 0x0a && b.length >= 685) {
    const ts = view.getUint32(7, true)
    const mags: number[] = []
    for (let i = 0; i < 100; i++) {
      const x = view.getInt16(85 + 2 * i, true)
      const y = view.getInt16(285 + 2 * i, true)
      const z = view.getInt16(485 + 2 * i, true)
      mags.push(Math.sqrt(x * x + y * y + z * z) / 4096)
    }
    return ts > 0 ? { ts, idx: 0, mags } : null
  }
  return null
}

// realtimeRr — extract beat-to-beat (R-R) intervals (ms) from the LIVE records that
// carry them, mirroring the reference implementation layout (and cross-validated: reference's R10 RR
// offset equals our R24's). Offsets are inner-relative (inner[0] = packet/record byte):
//   • 0x28 REALTIME_DATA (compact HR): rr_count u8 @ [9],  rr i16 LE @ [10 + 2i]
//   • R10  (rec_type 10, 0x2B/0x2F):   rr_count u8 @ [18], rr i16 LE @ [19 + 2i]
// (R24 historical RR is decoded separately in records.ts / parse_r24.)
//
// RR unit = raw u16 ms (confirmed). NOT yet hardware-validated on our firmware for the
// 0x28 carrier, so this is deliberately defensive: a count>8 (realtime carries 0–4) or
// any value the caller's 300–2000 ms gate rejects is dropped. A wrong offset therefore
// produces nothing storable — never a corrupted interval.
export function realtimeRr(hex: string): { ts: number; rr_ms: number[] } | null {
  let b: Uint8Array
  try { b = hexToBytes(hex) } catch { return null }
  if (b.length < 12) return null
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength)
  const pkt = b[0], rec = b[1]
  let tsOff: number, cntOff: number
  if (pkt === 0x28) { tsOff = 2; cntOff = 9 }
  else if (rec === 10) { tsOff = 7; cntOff = 18 }
  else return null
  if (cntOff + 1 >= b.length) return null
  const ts = view.getUint32(tsOff, true)
  if (ts <= 0) return null
  const n = b[cntOff]
  if (n === 0 || n > 8) return null // realtime carries 0–4; a large count = wrong offset → bail
  const rr_ms: number[] = []
  const first = cntOff + 1
  for (let i = 0; i < n && first + 2 * i + 2 <= b.length; i++) {
    const v = view.getInt16(first + 2 * i, true)
    if (v > 0) rr_ms.push(v) // drop 0-ms placeholders (matches R24 + reference)
  }
  return rr_ms.length ? { ts, rr_ms } : null
}

// Decode the R10 IMU arrays into (activity, steps) over the 100-sample window.
//   activity = stddev of per-sample |accel|(g)  — actigraphy intensity.
//   steps    = count of GAIT CYCLES only when the window is genuinely rhythmic.
//
// The band has no pedometer field — steps are estimated from wrist IMU (ESTIMATE
// tier). The naive "count every peak" approach over-counts badly: any arm gesture,
// typing, or vehicle bump clears a fixed threshold. Instead we require RHYTHM:
// walking produces a periodic acceleration signal, so we (1) detrend the magnitude
// to remove gravity + slow drift, (2) measure how periodic it is via normalized
// autocorrelation over plausible step lags, and (3) only count steps when that
// periodicity is strong AND the limb is actually moving. Steps in the window =
// number of gait cycles = n / (dominant lag). Non-rhythmic motion → 0 steps.
// (Same autocorrelation idea we use for respiratory rate; standard wrist pedometry.)
function r10Motion(view: DataView, len: number): { activity: number; steps: number } {
  if (len < 685) return { activity: 0, steps: 0 }
  const ACC = 1 / 4096
  const arr = (off: number): number[] => {
    const out: number[] = []
    for (let i = 0; i < 100; i++) {
      const o = off + 2 * i
      if (o + 2 <= len) out.push(view.getInt16(o, true))
    }
    return out
  }
  const ax = arr(85), ay = arr(285), az = arr(485) // accel X/Y/Z
  const n = Math.min(ax.length, ay.length, az.length)
  if (n === 0) return { activity: 0, steps: 0 }
  const mags: number[] = []
  for (let i = 0; i < n; i++) {
    mags.push(Math.hypot(ax[i] * ACC, ay[i] * ACC, az[i] * ACC))
  }
  const mean = mags.reduce((s, v) => s + v, 0) / n
  const variance = mags.reduce((s, v) => s + (v - mean) ** 2, 0) / n
  const std = Math.sqrt(variance)
  const activity = Math.round(std * 1000) / 1000

  // Limb must actually be oscillating — quiet wrist (typing/holding) → no steps.
  const ACTIVITY_FLOOR = 0.05 // g RMS of the detrended signal
  if (std < ACTIVITY_FLOOR || n < 24) return { activity, steps: 0 }

  // Detrend: remove a centered moving average (gravity + slow drift), leaving the
  // gait oscillation around 0.
  const W = 9
  const x: number[] = new Array(n);
  for (let i = 0; i < n; i++) {
    let s = 0, c = 0
    for (let j = Math.max(0, i - W); j <= Math.min(n - 1, i + W); j++) { s += mags[j]; c++ }
    x[i] = mags[i] - s / c
  }
  const x0 = x.reduce((s, v) => s + v, 0) / n
  let denom = 0
  for (let i = 0; i < n; i++) denom += (x[i] - x0) ** 2
  if (denom <= 1e-9) return { activity, steps: 0 }

  // Normalized autocorrelation over plausible step lags. Cadence ~1.4–3.0 steps/s;
  // with a ~25 Hz IMU window that's ~8–18 samples/step. We scan a generous band
  // and rely on the periodicity strength to confirm gait.
  const MIN_LAG = 7, MAX_LAG = 40
  let bestLag = 0, bestR = 0
  for (let lag = MIN_LAG; lag <= Math.min(MAX_LAG, n - 1); lag++) {
    let num = 0
    for (let i = 0; i < n - lag; i++) num += (x[i] - x0) * (x[i + lag] - x0)
    const r = num / denom
    if (r > bestR) { bestR = r; bestLag = lag }
  }

  // Strong, sustained periodicity ⇒ walking/running; count the gait cycles.
  const RHYTHM_THRESH = 0.45
  if (bestLag === 0 || bestR < RHYTHM_THRESH) return { activity, steps: 0 }
  const steps = Math.round(n / bestLag)
  return { activity, steps }
}

/**
 * Decode one hex record into a DecodedSample, or null if it carries no
 * surfaceable sample (0x33 IMU stream, malformed, or unknown type).
 */
export function decodeRecord(hex: string): DecodedSample | null {
  let b: Uint8Array
  try {
    b = hexToBytes(hex)
  } catch {
    return null
  }
  if (b.length < 4) return null
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength)
  const pktType = b[0]
  const recType = b[1]

  // 0x28 — live compact HR: ts@2 (u32 LE), hr@8 (u8). NO RR-intervals.
  if (pktType === 0x28) {
    if (b.length < 9) return null
    const ts = view.getUint32(2, true)
    const hr = b[8]
    return { ts, hr, activity: 0, steps_inc: 0, wrist_on: hr > 0, rec_type: 28 }
  }

  // 0x33 — live IMU stream: raw-only (kept in R2, no sample emitted).
  if (pktType === 0x33) return null

  if (b.length < 18) return null

  // R24 — type-24 historical telemetry.
  if (recType === 24) {
    const d = parse_r24(b)
    if (!d) return null
    return { ts: d.ts_epoch, hr: d.hr, activity: 0, steps_inc: 0, wrist_on: d.hr > 0, rec_type: 24 }
  }

  // R10 / 0x2B — ts@7, hr@17, IMU arrays → activity.
  if (recType === 10) {
    const ts = view.getUint32(7, true)
    const hr = b[17]
    const m = r10Motion(view, b.length)
    return { ts, hr, activity: m.activity, steps_inc: m.steps, wrist_on: hr > 0, rec_type: 10 }
  }

  return null
}

/** Decode a batch of hex records, returning all surfaceable samples. */
export function decodeBatch(records: string[]): DecodedSample[] {
  const out: DecodedSample[] = []
  for (const hex of records) {
    const s = decodeRecord(hex)
    if (s) out.push(s)
  }
  return out
}
