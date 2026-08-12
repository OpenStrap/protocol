// Protocol constants — WHOOP 4.0 protocol (Gen4 / "Harvard").
// PURE Dart. See PROTOCOL.md §1–2.

/// Gen4 / "Harvard" GATT service + characteristic UUIDs (the reference client uuids_for).
class GattUuids {
  static const String service = '61080001-8d6d-82b8-614a-1c8cb0f8dcc6';
  static const String cmdTo = '61080002-8d6d-82b8-614a-1c8cb0f8dcc6'; // write
  static const String cmdFrom =
      '61080003-8d6d-82b8-614a-1c8cb0f8dcc6'; // notify
  static const String events = '61080004-8d6d-82b8-614a-1c8cb0f8dcc6'; // notify
  static const String data = '61080005-8d6d-82b8-614a-1c8cb0f8dcc6'; // notify
  static const String memfault =
      '61080007-8d6d-82b8-614a-1c8cb0f8dcc6'; // notify
}

const int sof = 0xAA; // start of frame
const int revision1 = 0x01; // magic first byte for *_HARVARD / 2-byte toggles
const int hapticShortPulse = 2;

/// Packet type byte (inner[0]) —.
class PacketType {
  static const int command = 0x23;
  static const int commandResponse = 0x24;
  static const int realtimeData = 0x28;
  static const int realtimeRawData = 0x2B;
  static const int historicalData = 0x2F;
  static const int event = 0x30;
  static const int metadata = 0x31;
  static const int consoleLogs = 0x32;
  static const int realtimeImuStream = 0x33;
  static const int historicalImuStream = 0x34;
}

/// Command opcodes (inside a 0x23 COMMAND) —. Subset we use.
class Cmd {
  static const int linkValid = 0x01;
  // Report the highest wire-protocol revision the strap understands. Response
  // carries the max protocol version — used for feature gating.
  static const int getMaxProtocolVersion = 0x02;
  static const int toggleRealtimeHr = 0x03;
  static const int reportVersionInfo = 0x07;
  static const int setClock =
      0x0A; // [u32 epoch LE, u32 pad] — set the strap RTC
  static const int getClock = 0x0B; // → strap RTC epoch (ClockRef correlation)
  static const int abortHistoricalTransmits = 0x14;
  static const int sendHistoricalData = 0x16;
  static const int historicalDataResult = 0x17; // the batch ACK
  // DANGER — never send. Body is NOT empty and is NOT a range/erase: it is an
  // 8-byte `[u32 trim_page LE][u32 wrap_count LE]` — the
  // same 8 bytes as the HISTORY_END trim token. It advances the strap's flash
  // trim pointer, so a wrong value discards unsynced records.
  static const int forceTrim = 0x19;
  static const int getBatteryLevel = 0x1A;
  static const int rebootStrap = 0x1D; // DANGER
  // Hard power-cycle the strap (like pulling the battery). DANGER — never
  // auto-fire; only a deliberate, user-driven recovery action.
  static const int powerCycleStrap = 0x20; // DANGER
  static const int setReadPointer = 0x21;
  static const int getDataRange = 0x22;
  static const int getHelloHarvard = 0x23;
  // Device-update trio (Cmd opcode space — distinct from PacketType
  // 0x24 COMMAND_RESPONSE, which is inner[0], not a command opcode).
  // DANGER — never send.
  //
  // ⚠ These 0x24-0x26 values are the GEN4-EMPIRICAL numbering and could not
  // be confirmed on gen5. A gen5 strap does not act on them; the real gen5
  // device-update trio is 0x8E/0x8F/0x90 (= 142/143/144), which
  // [dangerousCmds] now also blocks. Keeping the gen4 entries because their
  // numbering cannot be disproven, not because it is confirmed.
  static const int startUpdateLoad = 0x24; // DANGER (gen4-empirical)
  static const int loadUpdateData = 0x25; // DANGER (gen4-empirical)
  static const int processUpdateImage = 0x26; // DANGER (gen4-empirical)
  static const int sendR10R11Realtime = 0x3F;
  // On-device haptic alarm. SET carries a wall-clock epoch + a haptic waveform
  // pattern (see cmdSetAlarm in commands.dart for the exact, hardware-verified
  // layout). The short "epoch only" form ACKs but never buzzes.
  static const int setAlarmTime = 0x42;
  static const int getAlarmTime = 0x43;
  static const int runAlarm = 0x44; // fire/test the alarm haptics immediately
  static const int disableAlarm = 0x45;
  static const int getAdvertisingNameHarvard = 0x4C;
  static const int setAdvertisingNameHarvard =
      0x4D; // [0x01][len u8][ascii name][u32 0]
  static const int getBodyLocationAndStatus = 0x54;
  static const int enterHighFreqSync = 0x60;
  static const int exitHighFreqSync = 0x61; // defensive stuck-strap recovery
  static const int getExtendedBatteryInfo = 0x62;
  static const int toggleImuMode = 0x6A;
  static const int enableOpticalData = 0x6B;
  static const int toggleOpticalMode = 0x6C;
  static const int runHapticsPattern = 0x4F;
  static const int stopHaptics = 0x7A;
  static const int selectWrist = 0x7B;
  static const int getHello = 0x91;
  static const int getBatteryPackInfo = 0x97;
  static const int togglePersistentR21 = 0x9A; // DANGER

  // ── gen5-exclusive opcode VALUES (replace the gen4 opcode of the same
  // purpose; see BandProfile — everything else in this class is shared
  // verbatim across generations) ──────────────────────────────────────────
  // Replaces SET_CLOCK (0x0A) on gen5.
  static const int setClockMaverick = 146;
  // Replaces GET_CLOCK (0x0B) on gen5.
  static const int getClockGen5 = 147;
  // gen5's Maverick haptic-buzz command. NOT the same opcode as gen4's
  // RUN_HAPTICS_PATTERN (0x4F/79) — "79/19 haptics-name-differs-not-value"
  // per the multiband spec: these are two genuinely distinct opcodes, not an
  // alias of the same numeric value.
  static const int runHapticPatternMaverick = 0x13; // 19
  // SET_DEVICE_CONFIG_VALUE — smaller/older sibling of SET_FF_VALUE (120).
  static const int setDeviceConfigValue = 119;
  // SET_FF_VALUE / SET_CONFIG — 40-byte name+value body. Shared opcode
  // number across generations; this is how the gen5 R22 deep-buffer enable
  // sequence is sent (see commands.dart's buildR22EnableSequence). NOTE: this
  // opcode is ALSO in [OpcodeSafety.forbidden] — see that class's doc for why
  // that is not a contradiction.
  static const int setFfValue = 120;
}

/// Band-agnostic opcode safety classification, sourced from whoop-rs's
/// hardware-tested command surface (kept SEPARATE from [dangerousCmds] above,
/// which is OpenStrap's own, independently-curated gen4 list — the two do not
/// fully overlap, e.g. this list omits the device-update opcodes (0x24-0x26)
/// that [dangerousCmds] already blocks, and adds a few whoop-rs flags ours
/// didn't have, notably 120/SET_FF_VALUE — see the note on [forbidden] below).
///
/// This class only PUBLISHES the classification; it does not enforce
/// anything itself — enforcement is a call-site concern (edge, at the point
/// it issues a command write), per the multiband port plan's recommendation
/// that the guard be "profile-data, not scattered logic".
class OpcodeSafety {
  /// Opcodes whoop-rs treats as never-safe-to-auto-fire. NOTE: 120
  /// (SET_FF_VALUE / SET_CONFIG) is in this list, yet [commands.dart]'s R22
  /// enable-sequence deliberately sends opcode 120 sixteen times — that is
  /// an intentional, explicit, user-opted-in action (the R22 deep-buffer
  /// opt-in), not the kind of accidental/automatic send this gate exists to
  /// stop. A call site enforcing this list needs an explicit allowlist for
  /// deliberate sequences like R22, not a blanket "opcode 120 → refuse".
  static const Set<int> forbidden = {
    10,
    146,
    25,
    29,
    32,
    45,
    77,
    119,
    120,
    99,
    123,
    142,
    143,
    144,
  };

  /// The subset of [forbidden] that is actively destructive (data loss /
  /// bricking), not merely "don't auto-fire". Opcodes 142-144 (0x8E-0x90) are
  /// the confirmed gen5 device-update trio — [dangerousCmds]
  /// also lists them so they are actually REFUSED, because this set is
  /// classification-only and self-enforces NOTHING (see the class doc). Treat
  /// membership here as documentation; gate on [dangerousCmds] to block a send.
  static const Set<int> destructive = {25, 45, 142, 143, 144};

  static bool isForbidden(int opcode) => forbidden.contains(opcode);
  static bool isDestructive(int opcode) => destructive.contains(opcode);
}

/// Commands that can brick the link / burn battery / brick flash. NEVER
/// auto-fire. CALLER-ENFORCED: this package builds frames but has no transport
/// write path, so it does not itself block a send — a call site (edge, at the
/// point it writes a command) is expected to check membership here and refuse.
/// This is the set such a guard should gate on (contrast [OpcodeSafety], which
/// only sub-classifies and is likewise not self-enforcing).
const Set<int> dangerousCmds = {
  Cmd.forceTrim,
  Cmd.togglePersistentR21,
  Cmd.rebootStrap,
  Cmd.powerCycleStrap,
  // gen4-empirical device-update numbering (unverified; inert on gen5).
  Cmd.startUpdateLoad,
  Cmd.loadUpdateData,
  Cmd.processUpdateImage,
  // CONFIRMED gen5 device-update trio (0x8E/0x8F/0x90 =
  // 142/143/144). These are the opcodes a real gen5 strap actually acts on, so
  // they must be in the enforced set — not merely classified in
  // [OpcodeSafety.destructive]. No Cmd.* constant: we never construct these.
  0x8E,
  0x8F,
  0x90,
};

/// Historical-data record type (inner[1] of a 0x2F / data packet).
class Record {
  static const int r10 = 10;
  static const int r12 = 12;
  static const int r21 = 21;
  static const int r24 = 24;
  static const int r25 = 25;
}

/// Metadata (sync) sub-type — inner[2] of a 0x31 METADATA packet.
class SyncMeta {
  static const int historyStart = 1; // informational — ignore
  static const int historyEnd = 2; // ACK with 0x17, then KEEP listening
  static const int historyComplete = 3; // finished — STOP, do not ACK
}

/// Event IDs (inner[2:4] of a 0x30 EVENT) —. Subset we act on.
class EventId {
  static const int batteryLevel = 3;
  static const int chargingOn = 7;
  static const int chargingOff = 8;
  static const int wristOn = 9;
  static const int wristOff = 10;
  static const int rtcLost = 13;
  static const int doubleTap = 14;
  static const int boot = 15;
  // The strap's RTC latched a new wall-clock time (emitted after a successful
  // SET_CLOCK). This is our authoritative confirmation the clock stuck.
  static const int setRtc = 16;
  static const int temperatureLevel = 17;
  static const int batteryPackConnected = 21;
  static const int batteryPackRemoved = 22;
  static const int bleBonded = 23;
  // gen5-only: toggling the realtime HR stream on/off is confirmed via these
  // events (gen4 has no equivalent confirmation event for this action).
  static const int bleRealtimeHrOn = 33;
  static const int bleRealtimeHrOff = 34;
  // Full-flash trim (data erase) started / finished on the strap.
  static const int trimAllData = 26;
  static const int trimAllDataEnded = 27;
  static const int flashInitComplete = 28;
  // Optical / accel front-end saturation warnings.
  static const int ch1Saturation = 40;
  static const int ch2Saturation = 41;
  static const int accelSaturation = 42;
  static const int rawDataCollectionOn = 46;
  static const int rawDataCollectionOff = 47;
  // Alarm lifecycle events — how the strap tells us the alarm latched and fired.
  // "strap-driven" = the strap's own scheduled alarm; "app-driven" = one we
  // triggered over BLE. These 56–59 events are the confirmation that our
  // SET_ALARM_TIME write actually took (the older short form never emitted them).
  static const int strapDrivenAlarmSet = 56;
  static const int strapDrivenAlarmExecuted = 57;
  static const int appDrivenAlarmExecuted = 58;
  static const int strapDrivenAlarmDisabled = 59;
  static const int hapticsFired = 60;
  static const int extendedBatteryInformation = 63;
  static const int highFreqSyncPrompt = 96;
  static const int highFreqSyncEnabled = 97;
  static const int highFreqSyncDisabled = 98;

  static String name(int id) {
    switch (id) {
      case batteryLevel:
        return 'BATTERY_LEVEL';
      case chargingOn:
        return 'CHARGING_ON';
      case chargingOff:
        return 'CHARGING_OFF';
      case wristOn:
        return 'WRIST_ON';
      case wristOff:
        return 'WRIST_OFF';
      case rtcLost:
        return 'RTC_LOST';
      case doubleTap:
        return 'DOUBLE_TAP';
      case boot:
        return 'BOOT';
      case setRtc:
        return 'SET_RTC';
      case temperatureLevel:
        return 'TEMPERATURE_LEVEL';
      case batteryPackConnected:
        return 'BATTERY_PACK_CONNECTED';
      case batteryPackRemoved:
        return 'BATTERY_PACK_REMOVED';
      case bleBonded:
        return 'BLE_BONDED';
      case bleRealtimeHrOn:
        return 'BLE_REALTIME_HR_ON';
      case bleRealtimeHrOff:
        return 'BLE_REALTIME_HR_OFF';
      case trimAllData:
        return 'TRIM_ALL_DATA';
      case trimAllDataEnded:
        return 'TRIM_ALL_DATA_ENDED';
      case flashInitComplete:
        return 'FLASH_INIT_COMPLETE';
      case ch1Saturation:
        return 'CH1_SATURATION_DETECTED';
      case ch2Saturation:
        return 'CH2_SATURATION_DETECTED';
      case accelSaturation:
        return 'ACCELEROMETER_SATURATION_DETECTED';
      case rawDataCollectionOn:
        return 'RAW_DATA_COLLECTION_ON';
      case rawDataCollectionOff:
        return 'RAW_DATA_COLLECTION_OFF';
      case strapDrivenAlarmSet:
        return 'STRAP_DRIVEN_ALARM_SET';
      case strapDrivenAlarmExecuted:
        return 'STRAP_DRIVEN_ALARM_EXECUTED';
      case appDrivenAlarmExecuted:
        return 'APP_DRIVEN_ALARM_EXECUTED';
      case strapDrivenAlarmDisabled:
        return 'STRAP_DRIVEN_ALARM_DISABLED';
      case hapticsFired:
        return 'HAPTICS_FIRED';
      case extendedBatteryInformation:
        return 'EXTENDED_BATTERY_INFORMATION';
      case highFreqSyncPrompt:
        return 'HIGH_FREQ_SYNC_PROMPT';
      case highFreqSyncEnabled:
        return 'HIGH_FREQ_SYNC_ENABLED';
      case highFreqSyncDisabled:
        return 'HIGH_FREQ_SYNC_DISABLED';
      default:
        return 'EVENT_$id';
    }
  }
}
