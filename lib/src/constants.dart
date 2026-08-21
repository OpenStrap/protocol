// Protocol constants — WHOOP 4.0 protocol (Gen4 / "Harvard").
// PURE Dart. See PROTOCOL.md §1–2.

const int sof = 0xAA; // start of frame
const int revision1 = 0x01; // magic first byte for *_HARVARD / 2-byte toggles
const int hapticShortPulse = 2;

/// Packet type byte (inner[0]) —.
class PacketType {
  static const int command = 0x23;
  static const int commandResponse = 0x24;
  // Battery-pack ("puffin") command/response. Type 37 has no known incoming
  // body shape, while type 38 does carry a battery-pack-command-specific
  // response — a future decode target.
  // Named here so neither is misread as 'other'.
  static const int puffinCommand = 0x25; // 37
  static const int puffinCommandResponse = 0x26; // 38
  static const int realtimeData = 0x28;
  static const int realtimeRawData = 0x2B;
  static const int historicalData = 0x2F;
  static const int event = 0x30;
  static const int metadata = 0x31;
  static const int consoleLogs = 0x32;
  static const int realtimeImuStream = 0x33;
  static const int historicalImuStream = 0x34;
  // Battery-pack event/log wrappers riding the generic event envelope.
  // 53/54/55 are MEMBERS of the Sensor-HPS history count: each complete
  // frame counts once and must be retained. 56 is battery-pack metadata
  // (start/end/complete), not a count member.
  //
  // 53 additionally carries a state-of-charge specialization that this
  // package does not decode yet.
  static const int relativePuffinEvents = 0x35; // 53
  static const int puffinEventsFromStrap = 0x36; // 54
  static const int relativeBatteryPackConsoleLogs = 0x37; // 55
  static const int puffinMetadata = 0x38; // 56
}

/// Command opcodes (inside a 0x23 COMMAND) —. Subset we use.
class Cmd {
  static const int linkValid = 0x01;
  // Report the highest wire-protocol revision the strap understands. Response
  // carries the max protocol version — used for feature gating.
  // GEN4-ONLY: not implemented on gen5, which silently no-ops it (no response).
  static const int getMaxProtocolVersion = 0x02;
  static const int toggleRealtimeHr = 0x03;
  // GEN4-ONLY: not implemented on gen5, which silently no-ops it.
  static const int reportVersionInfo = 0x07;
  // Generic HR service profile on/off. The setting is written to NV, so it
  // survives a reboot until explicitly changed back.
  static const int setGenericHrProfile = 0x0E;
  // Erase the bond / pairing keys. DANGER — the link drops and the user must
  // re-pair from scratch; there is no undo.
  static const int forgetBonds = 0x0F; // DANGER
  // Set the strap RTC. Body is TWO u32 LE: [0:4] whole epoch seconds, [4:8]
  // sub-seconds in 1/32768 s — NOT padding. Wrong length/shape is ACK'd but not
  // latched (see cmdSetClock), so build it there.
  static const int setClock = 0x0A;
  static const int getClock = 0x0B; // → strap RTC epoch (ClockRef correlation)
  static const int abortHistoricalTransmits = 0x14;
  static const int sendHistoricalData = 0x16;
  static const int historicalDataResult = 0x17; // the batch ACK
  // DANGER — never send. Body is NOT empty and is NOT a range/erase: it is an
  // 8-byte `[u32 trim_page LE][u32 wrap_count LE]` — the
  // same 8 bytes as the HISTORY_END trim token. NOT a range: the two words are
  // a single TARGET (trim_page, wrap_count) fed straight to the trim, so a
  // wrong value discards unsynced records. Two sentinels, both requiring the
  // pair: 0xFEFEFEFE erases everything, 0xFDFDFDFD resets the trim and read
  // pointers to oldest (i.e. re-serve all of flash). 0xFFFFFFFF in the first
  // word is a no-op, so it is a safe probe.
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
  // Toggle whether the strap pushes EVENT packets over the link. Body is the
  // bare state byte — this opcode takes NO revision byte. Safe.
  static const int sendEventPackets = 0x30;
  // Optical front-end (AFE) parameter set/get. SET retunes the sensor
  // front-end, so it can degrade the strap's own HR quality — treat as
  // advanced/diagnostic. GET is read-only and safe.
  static const int setAfeParams = 0x3D;
  static const int getAfeParams = 0x3E;
  // GEN4-ONLY: gen5 does not implement 0x3F at all. gen5's realtime-raw entry
  // point is START_RAW_DATA (0x51) / STOP_RAW_DATA (0x52) instead.
  static const int sendR10R11Realtime = 0x3F;
  // gen5 realtime raw start/stop — THE gen5 realtime-raw entry point. Revision
  // 1 of START defaults the collection duration to 86,400,000 (a full day), so
  // always send revision 2 with an explicit bounded duration. Safe, but a raw
  // flood is a battery cost: always pair a start with a stop.
  static const int startRawData = 0x51;
  static const int stopRawData = 0x52;
  // On-device haptic alarm. SET carries a wall-clock epoch + a haptic waveform
  // pattern (see cmdSetAlarm in commands.dart for the exact, hardware-verified
  // layout). The short "epoch only" form ACKs but never buzzes.
  static const int setAlarmTime = 0x42;
  static const int getAlarmTime = 0x43;
  static const int runAlarm = 0x44; // fire/test the alarm haptics immediately
  static const int disableAlarm = 0x45;
  // GEN4-ONLY (both): not implemented on gen5. The gen5 equivalents are
  // SET/GET_CUSTOM_ADVERTISING_NAME (0x8C / 0x8D).
  static const int getAdvertisingNameHarvard = 0x4C;
  static const int setAdvertisingNameHarvard =
      0x4D; // [0x01][len u8][ascii name][u32 0]
  static const int getBodyLocationAndStatus = 0x54;
  static const int enterHighFreqSync = 0x60;
  static const int exitHighFreqSync = 0x61; // defensive stuck-strap recovery
  // GEN4-ONLY: not implemented on gen5 (which reports pack state via
  // GET_BATTERY_PACK_INFO, 0x97).
  static const int getExtendedBatteryInfo = 0x62;
  // Turn the BLE UART (console/log) service off. Safe, but it is how console
  // logs stop arriving — do not send it while debugging.
  static const int disableBleUart = 0x67;
  // Writes no non-volatile CONFIG, despite the name — it posts an event and
  // nothing else. Not the same as harmless: the capture it starts keeps writing
  // IMU records to the flash log until it is switched off or the strap reboots.
  // The persistent IMU save is TOGGLE_PERSISTENT_R21 (0x9A), gated below.
  static const int saveImuData = 0x69;
  static const int toggleImuMode = 0x6A;
  static const int enableOpticalData = 0x6B;
  static const int toggleOpticalMode = 0x6C;
  // Config + feature-flag key exchange: the enumerate/fetch pair for each
  // namespace, then the by-name value reads. All read-only and safe.
  static const int getConfigKeyCount = 0x73;
  static const int getConfigKeyName = 0x74;
  static const int getFlagKeyCount = 0x75;
  static const int getFlagKeyName = 0x76;
  static const int getConfigValue = 0x79;
  static const int getFlagValue = 0x80;
  // GEN4-ONLY: not implemented on gen5, which buzzes via
  // RUN_HAPTIC_PATTERN_MAVERICK (0x13) instead.
  static const int runHapticsPattern = 0x4F;
  static const int stopHaptics = 0x7A; // safe: cancels an in-progress buzz
  // Wrist selection — also the wrist selector for a filtered-reading (R17)
  // session, whose prepare step sends it right after the abort. Safe.
  static const int selectWrist = 0x7B;
  // Filtered reading — WHOOP's internal name is "Labrador"; the trace arrives
  // as record revision 17. Three toggles; every body is
  // `[revision 01][operation]`:
  //   124 TOGGLE_LABRADOR_DATA_GENERATION — 01=stop, 02=start, 03=restart.
  //       An OPERATION byte, NOT a boolean: `01 01` is the STOP operation.
  //   125 TOGGLE_LABRADOR_RAW_SAVE       — 00=disable, 01=enable.
  //   139 TOGGLE_LABRADOR_FILTERED       — 00=disable, 01=enable.
  // Safe, but a reading is a battery cost, and there is no auto-rollback: a
  // partial startup leaves components enabled until the caller sends the OFFs.
  // See commands.dart's cmdLabradorDataGeneration for the full sequence.
  static const int toggleLabradorDataGeneration = 0x7C; // 124
  static const int toggleLabradorRawSave = 0x7D; // 125
  static const int toggleLabradorFiltered = 0x8B; // 139
  // ── Deprecated "ECG" spellings of the three above ─────────────────────────
  // The feature was previously modelled as an ECG arm/save/send matrix. The
  // opcode NUMBERS 124/125/139 are right; the names and the arm/disarm mental
  // model are not (see the operation table above).
  @Deprecated('this is TOGGLE_LABRADOR_DATA_GENERATION (124): its body is an '
      'operation byte (01=stop, 02=start, 03=restart), not an on/off flag — '
      'use Cmd.toggleLabradorDataGeneration')
  static const int ecgMainControl = 0x7C;
  @Deprecated('this is TOGGLE_LABRADOR_RAW_SAVE (125), 01 00 / 01 01 — '
      'use Cmd.toggleLabradorRawSave')
  static const int ecgSaveRawData = 0x7D;
  @Deprecated('opcode 126 (0x7E) is NOT an established WHOOP 5 opcode '
      '— origin unknown, most likely gen4 '
      'or third-party lore. The raw trace is TOGGLE_LABRADOR_RAW_SAVE (125): '
      'use Cmd.toggleLabradorRawSave')
  static const int ecgSendRawData = 0x7E;
  @Deprecated('opcode 127 (0x7F) is NOT an established WHOOP 5 opcode '
      '— origin unknown, most likely gen4 '
      'or third-party lore. The filtered trace is TOGGLE_LABRADOR_FILTERED '
      '(139): use Cmd.toggleLabradorFiltered')
  static const int ecgSaveFilteredData = 0x7F;
  @Deprecated('this is TOGGLE_LABRADOR_FILTERED (139), 01 00 / 01 01 — '
      'use Cmd.toggleLabradorFiltered')
  static const int ecgSendFilteredData = 0x8B;
  // Signal-processing configuration. Advanced/diagnostic: it retunes the
  // on-strap algorithms, so it can change what the strap itself reports.
  static const int setSignalConfig = 0x8A;
  // gen5 custom advertising name set/get — the gen5 equivalents of gen4's
  // 0x4C/0x4D, which gen5 does not implement. Safe.
  static const int setCustomAdvertisingName = 0x8C;
  static const int getCustomAdvertisingName = 0x8D;
  static const int getHello = 0x91;
  // Override the strap's on/off-body decision. Advanced: while overridden the
  // strap's own wear detection no longer reflects reality.
  static const int wearDetectOverride = 0x94;
  // LED accessibility mode. Writes the non-volatile config store, so it
  // survives a reboot — see dangerousCmds.
  static const int setLedAccessibility = 0x95;
  // Gyroscope enable / status. Safe, but the gyro is a real power draw.
  static const int gyroEnable = 0x96;
  static const int gyroStatus = 0x98;
  static const int getBatteryPackInfo = 0x97;
  static const int togglePersistentR21 = 0x9A; // DANGER — persistent IMU save
  // Persistent OPTICAL save — the twin of 0x9A (persistent IMU save). DANGER:
  // this is the one that leaves the optical LEDs running across reconnects and
  // reboots, i.e. the stuck-LED / battery-drain footgun.
  static const int persistentOpticalSave = 0x99; // DANGER

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
  // SET_FF_VALUE / SET_CONFIG. Shared opcode number across generations; the
  // only body shape this package builds is gen5's 65 bytes —
  // `[0x01 revision][name:32B NUL-padded ASCII][value:32B NUL-padded ASCII]`,
  // see cmdSetConfigGen5. (An earlier note here said 40 bytes: that is the
  // revision-less form the strap REJECTED.) This is how the gen5 R22
  // deep-buffer enable sequence is sent (see commands.dart's
  // buildR22EnableSequence). NOTE: this
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
  // Same 8-byte `[u32 read_page LE][u32 wrap_count LE]` shape as FORCE_TRIM:
  // it moves the strap's flash READ pointer, so a wrong value skips past
  // unsynced records (they are never served again) or replays old ones.
  Cmd.setReadPointer,
  Cmd.togglePersistentR21,
  // Persistent CONFIG writes. These land in non-volatile storage and survive a
  // reboot, so a wrong value is not undone by disconnecting — writing the
  // default back is the only way out. buildR22EnableSequence goes around this
  // gate deliberately (it is opt-in and ships a restore-defaults companion);
  // nothing else should reach them by accident.
  Cmd.setDeviceConfigValue,
  Cmd.setFfValue,
  Cmd.setGenericHrProfile,
  // Forces the strap to believe it is on-wrist: sensors keep running off the
  // body, and it persists.
  Cmd.wearDetectOverride,
  // Persistent optical save — the stuck-LED / battery-drain footgun.
  Cmd.persistentOpticalSave,
  // Both write the non-volatile config store, and neither has a caller: gating
  // them costs nothing today and stops an accidental first use.
  //
  // The persistent commands behind a user action — alarms, strap rename — are
  // deliberately NOT here, same carve-out as the R22 sequence below: this gate
  // exists to stop a command being sent by accident, not to stop one the user
  // asked for. Note that is about intent, not mechanism — arming an alarm has a
  // grace-window retry timer that re-sends it, so "no automatic path" would be
  // too strong a claim.
  Cmd.setLedAccessibility,
  Cmd.setSignalConfig,
  // Erases the pairing: the link drops and the user must re-pair by hand.
  Cmd.forgetBonds,
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
///
/// ⚠ These are the GEN4 record versions. gen5 builds a DIFFERENT set —
/// 16, 17, 18, 20, 21, 22 and 26 — and never builds 24, so a gen5 link will
/// not deliver [r24] no matter what is requested. The gen5-specific decoders
/// live in gen5_records.dart; the ids named here are only the identifiers.
class Record {
  static const int r10 = 10;
  static const int r12 = 12;
  static const int r16 = 16; // gen5: raw ECG
  static const int r17 = 17; // gen5: filtered ECG
  static const int r21 = 21;
  static const int r22 = 22; // gen5: research
  static const int r24 = 24; // gen4 only — never built by gen5
  static const int r25 = 25;
  static const int r26 = 26; // gen5: PIP
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

  /// Skin-temperature level. The event id is 111 — NOT 17, which is a
  /// different event entirely and never carries a temperature.
  static const int temperatureLevel = 111;
  static const int batteryPackConnected = 21;
  static const int batteryPackRemoved = 22;

  /// BLE bond established. The event id is 31 — NOT 23; a listener waiting on
  /// 23 never sees the bond complete.
  static const int bleBonded = 31;
  // gen5-only: toggling the realtime HR stream on/off is confirmed via these
  // events (gen4 has no equivalent confirmation event for this action).
  static const int bleRealtimeHrOn = 33;
  static const int bleRealtimeHrOff = 34;
  // Full-flash trim (data erase) started / finished on the strap.
  static const int trimAllData = 26;
  static const int trimAllDataEnded = 27;
  static const int flashInitComplete = 28;

  /// Live strap-condition telemetry the band volunteers: how far the host is
  /// behind flash, plus charge/wear condition.
  /// The page backlog it reports is the same quantity as GET_DATA_RANGE's
  /// `pages_behind` — a modular PAGE span (~15 records/page nominal),
  /// never a packet count.
  static const int strapConditionReport = 29;
  // Optical / accel front-end saturation warnings.
  //
  // ⚠ NEVER EMITTED. 40/41/42 are defined ids but nothing on the strap raises
  // them, so saturation is not observable this way — do not gate anything on
  // one arriving, and never wait for one.
  static const int ch1Saturation = 40;
  static const int ch2Saturation = 41;
  static const int accelSaturation = 42;
  // ⚠ NEVER EMITTED. 46/47 are defined ids the strap does not raise: raw-data
  // collection starting/stopping is NOT reported as an event. Confirm a raw
  // stream from the data packets themselves, not from these.
  static const int rawDataCollectionOn = 46;
  static const int rawDataCollectionOff = 47;
  // Alarm lifecycle events — how the strap tells us the alarm latched and fired.
  // "strap-driven" = the strap's own scheduled alarm; "app-driven" = one we
  // triggered over BLE. These 56–59 events are the confirmation that our
  // SET_ALARM_TIME write actually took (the older short form never emitted them).
  // Only 56 and 57 actually arrive.
  static const int strapDrivenAlarmSet = 56;
  static const int strapDrivenAlarmExecuted = 57;
  // ⚠ NEVER EMITTED (58/59). An app-triggered alarm run and an alarm being
  // disabled are not reported as events — confirm those from the command
  // response instead. Nothing may block waiting on either of these.
  static const int appDrivenAlarmExecuted = 58;
  static const int strapDrivenAlarmDisabled = 59;
  static const int hapticsFired = 60;
  static const int extendedBatteryInformation = 63;
  static const int highFreqSyncPrompt = 96;
  static const int highFreqSyncEnabled = 97;
  static const int highFreqSyncDisabled = 98;

  /// A running haptics pattern stopped, and WHY:
  /// it expired, it errored, or the wearer double-tapped it away. This is the
  /// only way to learn an alarm was dismissed rather than timing out.
  static const int hapticsTerminated = 100;

  /// The battery pack (puck) describing itself — address, name, charge,
  /// colourway, hardware family. Same content as
  /// the GET_BATTERY_PACK_INFO(151) reply, volunteered as an event.
  static const int batteryPackInfo = 109;

  /// Firmware-internal event wrapper carrying its own u16 sub-id
  /// (see [FirmwareEventId]).
  static const int genericFirmwareEvent = 123;

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
      case strapConditionReport:
        return 'STRAP_CONDITION_REPORT';
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
      case hapticsTerminated:
        return 'HAPTICS_TERMINATED';
      case batteryPackInfo:
        return 'BATTERY_PACK_INFO';
      case genericFirmwareEvent:
        return 'GENERIC_FIRMWARE_EVENT';
      default:
        return 'EVENT_$id';
    }
  }
}

/// Why a running haptics pattern stopped — body[1] of an
/// [EventId.hapticsTerminated] event.
///
/// The three causes are distinct and must not be collapsed: an alarm that ran
/// its full duration, one the firmware aborted, and one the WEARER dismissed
/// with a double tap.
class HapticsTermination {
  static const int expired = 0;
  static const int error = 1;
  static const int userDoubleTap = 2;

  static String name(int code) {
    switch (code) {
      case expired:
        return 'expired';
      case error:
        return 'error';
      case userDoubleTap:
        return 'user_double_tap';
      default:
        return 'code_$code';
    }
  }
}

/// The haptics/alarm status byte carried by the SET_ALARM_TIME(66) and
/// RUN_ALARM(68) responses at response-body offset 1.
///
/// This is **in addition to** the ordinary outer command result — a caller
/// must check both. A response can carry SUCCESS as its outer result and still
/// report here that the alarm was refused, which is the whole reason the byte
/// exists: it is the only place the strap says *why*.
class AlarmStatus {
  static const int unknown = 0;
  static const int validInputPattern = 1;
  static const int invalidWaveformEffect = 2;
  static const int invalidLoopCount = 3;
  static const int invalidDuration = 4;
  static const int playedSuccessfully = 5;
  static const int hapticsFailure = 6;
  static const int hapticsTimeout = 7;
  static const int hapticsBusy = 8;
  static const int hapticsStopped = 9;
  static const int invalidAlarmTime = 10;
  static const int invalidAlarmId = 11;

  /// The input-validation family: the strap examined what we sent and refused
  /// it. Separated from the run-time outcomes (6..9), which say a pattern that
  /// WAS accepted then failed, timed out, was busy or was stopped — a host
  /// must not treat "haptics busy" as "your alarm is not armed".
  static bool isInputRejection(int code) =>
      code == invalidWaveformEffect ||
      code == invalidLoopCount ||
      code == invalidDuration ||
      code == invalidAlarmTime ||
      code == invalidAlarmId;

  static String name(int code) {
    switch (code) {
      case unknown:
        return 'unknown';
      case validInputPattern:
        return 'valid_input_pattern';
      case invalidWaveformEffect:
        return 'invalid_waveform_effect';
      case invalidLoopCount:
        return 'invalid_loop_count';
      case invalidDuration:
        return 'invalid_duration';
      case playedSuccessfully:
        return 'played_successfully';
      case hapticsFailure:
        return 'haptics_failure';
      case hapticsTimeout:
        return 'haptics_timeout';
      case hapticsBusy:
        return 'haptics_busy';
      case hapticsStopped:
        return 'haptics_stopped';
      case invalidAlarmTime:
        return 'invalid_alarm_time';
      case invalidAlarmId:
        return 'invalid_alarm_id';
      default:
        return 'code_$code';
    }
  }
}

/// Sub-ids carried by an [EventId.genericFirmwareEvent] (u16 LE at body[1]).
/// Only one is named in the reference tables (doc 99); everything else stays
/// numeric rather than being guessed at.
class FirmwareEventId {
  static const int dorsetDetected = 6;

  static String name(int id) =>
      id == dorsetDetected ? 'DORSET_DETECTED' : 'FIRMWARE_EVENT_$id';
}
