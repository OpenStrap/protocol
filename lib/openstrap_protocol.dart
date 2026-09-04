/// openstrap_protocol — pure-Dart, multi-band BLE protocol library.
///
/// Combines the TS record decoders (parse_r24 / live decoders) with the edge
/// framing / CRC / command / control-plane code into one bytes <-> records
/// library, plus the wire format for every other band this project speaks to.
/// No runtime dependencies; dart:typed_data / dart:convert / dart:math only —
/// a band whose wire format needs a crypto primitive (Oura's AES-128/ECB auth
/// response) keeps that one piece with the session that drives it, one layer
/// up, rather than adding a dependency here.
library openstrap_protocol;

// Source 0 — multi-band wire-format profile (gen4 / gen5).
export 'src/band.dart' show DeviceType, GattProfile, BandProfile;

// Source 0b — other bands' wire formats. Function names are prefixed
// (`parseOuraFrame`, not `parseFrame`) precisely because this library already
// has a `parseFrame`/`parseEvent` for WHOOP's framed envelope — two bands
// sharing one barrel must not share a bare verb.
export 'src/oura.dart';
export 'src/hrs.dart';
export 'src/o2ring.dart';

// Source 1 — record decoders.
export 'src/records.dart'
    show
        R24,
        parseR24,
        FirmwareAwareR24Decoder,
        R24DecodeStrategy,
        // The historical versions parseR24 can actually decode. Exported so a
        // caller routes on the real set instead of keeping its own copy, which
        // silently rots the day this one grows.
        kKnownRecordVersions;
// gen5 historical-record decoders (v18/v20/v21/v22/v26) — see gen5_records.dart
// for why these replace the old, wrong parseGen5Record/{9,12,24} set.
export 'src/gen5_records.dart'
    show
        Gen5HistoricalHeader,
        Gen5HistoricalRecord,
        Gen5HistorySample,
        Gen5OpticalBlock,
        Gen5OpticalBuffer,
        Gen5ImuBuffer,
        Gen5PpgReconstruction,
        Gen5PpgWaveform,
        Gen5RecordDecoder,
        Gen5ResearchOpticalWindow,
        Gen5ResearchRecord,
        Gen5SleepState,
        Gen5V18Decoder,
        Gen5V20Decoder,
        Gen5V21Decoder,
        Gen5V22Decoder,
        Gen5V26Decoder,
        kGen5HistoricalDecoders,
        kGen5V22KnownTags,
        kGen5V22InnerLen,
        // The exact lengths are the live names; the *MinInnerLen* aliases below
        // are deprecated and exported only so existing callers still resolve.
        kGen5V18InnerLen,
        kGen5V26InnerLen,
        kGen5V18MinInnerLen,
        kGen5V20InnerLen,
        kGen5V21InnerLen,
        kGen5V26MinInnerLen,
        kGen5V26MinInnerLenWithMeta,
        kGen5AccelScaleG,
        kGen5GyroScaleDps,
        isGen5ImuBuffer,
        parseGen5ImuBuffer,
        parseGen5Historical,
        reconstructSaturatedDeltaWindow;
export 'src/live.dart'
    show
        DecodedSample,
        ImuFrame,
        RealtimeRrResult,
        R10Imu,
        R11Raw,
        hexToBytes,
        frameAccel,
        frameAccelGen5Live,
        frameAccelForBand,
        realtimeRr,
        decodeR10Imu,
        decodeR11Raw,
        decodeRecord,
        decodeBatch;

// Source 2 — CRC, constants, framing, commands.
export 'src/crc.dart' show crc8, crc32, crc16Modbus;
export 'src/constants.dart';
export 'src/framing.dart'
    show Frame, pad4, buildFrame, parseFrame, FrameReassembler;
export 'src/commands.dart'
    show
        buildCommand,
        buildHistoryResultOk,
        buildHistoryResultFail,
        buildBatchAck,
        initPackets,
        WristSelection,
        LabradorOperation,
        cmdLinkValid,
        cmdGetBattery,
        cmdGetHello,
        cmdGetHelloModern,
        cmdAbortHistorical,
        cmdSendHistorical,
        cmdGetClock,
        cmdGetDataRange,
        cmdSetClock,
        cmdReportVersionInfo,
        cmdGetBodyLocationAndStatus,
        cmdGetBatteryPackInfo,
        cmdEnterHighFreqSync,
        cmdExitHighFreqSync,
        cmdSelectWrist,
        cmdToggleHr,
        cmdSendR10R11,
        cmdToggleImu,
        cmdEnableOptical,
        cmdBuzz,
        cmdSetAlarm,
        cmdSetAlarmRev1,
        alarmRev1Payload,
        cmdSetAlarmSimple,
        cmdRunAlarm,
        cmdDisableAlarm,
        kDefaultAlarmHaptics,
        gen5ClientHello,
        cmdGetDataRangeGen5,
        cmdSendHistoricalGen5,
        cmdSetClockGen5,
        cmdGetClockGen5,
        cmdBuzzGen5Maverick,
        cmdSetConfigGen5,
        cmdSetDeviceConfigValueGen5,
        kGen5R22EnableFlags,
        kGen5R22ContestedFlagNames,
        buildR22EnableSequence,
        // Previously built + unit-tested but unreachable from this entry point.
        // Every opcode below is an established WHOOP opcode, so a caller
        // is reaching for something the band is known to implement.
        //
        // NOT exported, deliberately:
        //  • buildR22RestoreDefaultsSequence — writes raw '0' to every flag,
        //    which is not a valid boolean write value ('1'/'2' only; raw 0
        //    = unset) and not the observed pre-value, so it is not a
        //    correct restore. A correct restore is snapshot-based (GET each
        //    flag first, write back the recorded value with readback).
        //  • cmdGyroEnable (150) / cmdGyroStatus (152) / cmdSetEventPackets
        //    (48) — these opcode NUMBERS are not established WHOOP opcodes.
        //    They came from third-party sources, the same origin as the
        //    unverified 146/147 "Maverick clock" opcodes.
        //    They stay built and tested but unexported
        //    until a trace or a hardware capture backs them; shipping them as
        //    public API would present a guess as a capability.
        cmdGetAlarmTime, // 67
        cmdRawDataStart, // 81
        cmdRawDataStop, // 82
        cmdStopHaptics, // 122
        // Filtered reading ("Labrador", R17). The wrong-bodied cmdEcgControl
        // (124 as a bool) and the opcode-126 cmdEcgSendRaw stay deprecated
        // and unexported.
        cmdLabradorDataGeneration, // 124 — R17 lifecycle
        cmdLabradorRawSave, // 125 — R17 lifecycle
        cmdLabradorFiltered, // 139 — R17 lifecycle
        cmdGetCustomAdvertisingName, // 141
        cmdSetCustomAdvertisingName, // 140 — PERSISTENT write
        cmdGetConfigKeyCount, // 115
        cmdGetConfigKeyName, // 116
        cmdGetFlagKeyCount, // 117
        cmdGetFlagKeyName, // 118
        cmdGetConfigValue, // 121 (read-only)
        cmdGetFlagValue; // 128 (read-only)

// Control-plane parsers (HELLO / EVENT / METADATA / COMMAND_RESPONSE / dispatch).
export 'src/control.dart'
    show
        R10Lite,
        parseR10Lite,
        RealtimeHr,
        parseRealtimeHr,
        GarmentDeviceLocation,
        BatteryPackType,
        BodyLocationStatusResponse,
        HighFreqSyncResponse,
        SelectWristResponse,
        BatteryPackInfoResponse,
        RealtimeHrV2,
        parseRealtimeHrV2,
        HelloInfo,
        parseHello,
        Gen5HelloInfo,
        EventInfo,
        parseEvent,
        CmdResponse,
        parseCommandResponse,
        MetaMarker,
        parseMetadata,
        ConsoleLogChunk,
        parseConsoleLog,
        ConsoleLogReassembler,
        Decoded,
        decodeFrame;
