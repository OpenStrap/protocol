/// openstrap_protocol — pure-Dart WHOOP 4.0 protocol library.
///
/// Combines the TS record decoders (parse_r24 / live decoders) with the edge
/// framing / CRC / command / control-plane code into one bytes <-> records
/// library. No runtime dependencies; dart:typed_data / dart:convert / dart:math
/// only.
library openstrap_protocol;

// Source 0 — multi-band wire-format profile (gen4 / gen5).
export 'src/band.dart' show DeviceType, GattProfile, BandProfile;

// Source 1 — record decoders.
export 'src/records.dart'
    show R24, parseR24, FirmwareAwareR24Decoder, R24DecodeStrategy;
// gen5 historical-record decoders (v18/v20/v21/v26) — see gen5_records.dart
// for why these replace the old, wrong parseGen5Record/{9,12,24} set.
export 'src/gen5_records.dart'
    show
        Gen5HistoricalHeader,
        Gen5HistoricalRecord,
        Gen5HistorySample,
        Gen5OpticalBlock,
        Gen5OpticalBuffer,
        Gen5ImuBuffer,
        Gen5PpgWaveform,
        Gen5RecordDecoder,
        Gen5SleepState,
        Gen5V18Decoder,
        Gen5V20Decoder,
        Gen5V21Decoder,
        Gen5V26Decoder,
        kGen5HistoricalDecoders,
        kGen5V18MinInnerLen,
        kGen5V20InnerLen,
        kGen5V21InnerLen,
        kGen5V26MinInnerLen,
        parseGen5Historical;
export 'src/live.dart'
    show
        DecodedSample,
        ImuFrame,
        RealtimeRrResult,
        R10Imu,
        hexToBytes,
        frameAccel,
        realtimeRr,
        decodeR10Imu,
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
        buildR22EnableSequence;

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
