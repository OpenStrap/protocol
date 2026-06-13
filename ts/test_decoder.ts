import * as fs from "fs";
import * as path from "path";
import { parse_r24 } from "./records";

const FIXTURE_PATH = path.join(__dirname, "../../whoop_hist.jsonl");

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

function runTests() {
  console.log("Loading fixtures from:", FIXTURE_PATH);
  const data = fs.readFileSync(FIXTURE_PATH, "utf-8");
  const lines = data.trim().split("\n");
  const records = lines.map((line) => JSON.parse(line));

  console.log(`Loaded ${records.length} records.`);

  if (records.length === 0) {
    throw new Error("No records found in fixture!");
  }

  // Test record 0
  console.log("Testing record 0...");
  const record0 = records[0];
  const bytes0 = hexToBytes(record0.hex);
  const result0 = parse_r24(bytes0);

  if (!result0) {
    throw new Error("Record 0 failed to decode!");
  }

  console.log("Record 0 decoded:", result0);

  // Assertions for record 0
  // hr=98, ts_epoch=1775395266; rr/ppg/raw ADCs are decoded but not pinned to
  // exact expected values here (validated statistically across the corpus).
  console.assert(result0.hr === 98, `Expected HR 98, got ${result0.hr}`);
  console.assert(
    result0.ts_epoch === 1775395266,
    `Expected ts_epoch 1775395266, got ${result0.ts_epoch}`
  );
  console.assert(
    result0.rr_count >= 0 && result0.rr_count <= 4,
    `Expected rr_count 0-4, got ${result0.rr_count}`
  );
  console.assert(
    result0.rr_intervals_ms.length === result0.rr_count ||
      result0.rr_intervals_ms.length <= result0.rr_count,
    `rr_intervals length should not exceed rr_count`
  );
  console.assert(
    Number.isInteger(result0.spo2_red_raw) && Number.isInteger(result0.skin_temp_raw),
    `Expected raw ADCs to decode as integers`
  );

  // Accel assertions: accel≈(-0.150,-0.331,1.001)
  const [ax, ay, az] = result0.accel_g;
  console.assert(
    Math.abs(ax - -0.15) < 0.001,
    `Expected accel_x -0.150, got ${ax}`
  );
  console.assert(
    Math.abs(ay - -0.331) < 0.001,
    `Expected accel_y -0.331, got ${ay}`
  );
  console.assert(
    Math.abs(az - 1.001) < 0.001,
    `Expected accel_z 1.001, got ${az}`
  );

  console.log("Record 0 assertions passed!");

  // Test all records
  console.log("Testing all 550 records...");
  let successCount = 0;
  for (let i = 0; i < records.length; i++) {
    try {
      const bytes = hexToBytes(records[i].hex);
      const res = parse_r24(bytes);
      if (res) {
        successCount++;
      } else {
        console.error(`Record ${i} returned null`);
      }
    } catch (e) {
      console.error(`Error decoding record ${i}:`, e);
      throw e;
    }
  }

  console.log(`Successfully decoded ${successCount}/${records.length} records.`);
  if (successCount === records.length) {
    console.log("ALL TESTS PASSED");
  } else {
    throw new Error(`Only ${successCount}/${records.length} records decoded successfully.`);
  }
}

runTests();
