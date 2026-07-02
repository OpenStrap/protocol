/// openstrap_protocol — pure-Dart WHOOP 4.0 protocol library.
///
/// Combines the TS record decoders (parse_r24 / live decoders) with the edge
/// framing / CRC / command / control-plane code into one bytes <-> records
/// library. No runtime dependencies; dart:typed_data / dart:convert / dart:math
/// only.
library openstrap_protocol;

// Source 1 — record decoders.
export 'src/records.dart' show R24, parseR24;
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
export 'src/crc.dart' show crc8, crc32;
export 'src/constants.dart';
export 'src/framing.dart'
    show Frame, pad4, buildFrame, parseFrame, FrameReassembler;
export 'src/commands.dart'
    show
        buildCommand,
        buildBatchAck,
        initPackets,
        WristSelection,
        cmdLinkValid,
        cmdGetBattery,
        cmdGetHello,
        cmdGetHelloModern,
        cmdAbortHistorical,
        cmdSendHistorical,
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
        cmdSetAlarm;

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
        Decoded,
        decodeFrame;
