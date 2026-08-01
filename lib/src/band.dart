// band.dart — multi-generation ("multi-band") wire-format profile.
//
// WHOOP 4 (gen4 / "Harvard") and WHOOP 5 (gen5 / "fd4b") are NOT two different
// protocols — gen5 is gen4 in a different envelope. Everything that actually
// differs between generations is captured here so the rest of the stack
// (framing, records, edge BLE) can stay band-agnostic and just carry a
// [BandProfile] around.
//
// Verified deltas (see MULTIBAND_WHOOP5_PORT_PLAN.md):
//   • frame header: 4 bytes + crc8  →  8 bytes + crc16-modbus
//   • payload CRC:  crc32 on BOTH   (unchanged)
//   • command opcodes: shared, EXCEPT HELLO (gen5 = 0x91)
//   • GATT service base: 6108000x-…  →  fd4b000x-…  (same low-nibble map)
//
// PURE Dart — dart:typed_data only.

import 'dart:typed_data';
import 'crc.dart';
import 'constants.dart';

/// Which physical WHOOP generation / wire format a link is speaking.
///
/// gen5 covers the whole fd4b family (WHOOP 5.0 "Goose", "Maverick"/MG,
/// "Puffin" battery pack) — they share one wire format; only packet-level
/// sub-types (Puffin) differ, which is handled above the frame layer.
enum DeviceType { gen4, gen5 }

/// GATT service + characteristic UUIDs for one generation. The low nibble is
/// identical across generations (0001 service, 0002 write, 0003 cmd-from,
/// 0004 events, 0005 data, 0007 memfault); only the 32-bit prefix + 96-bit
/// base suffix change.
class GattProfile {
  final String service;
  final String cmdTo; // write w/response  (app → strap)
  final String cmdFrom; // notify command responses (strap → app)
  final String events; // notify strap events
  final String data; // notify data/history packets
  final String memfault;

  const GattProfile({
    required this.service,
    required this.cmdTo,
    required this.cmdFrom,
    required this.events,
    required this.data,
    required this.memfault,
  });

  /// WHOOP 4 — base `6108000x-8d6d-82b8-614a-1c8cb0f8dcc6`.
  static const GattProfile gen4 = GattProfile(
    service: '61080001-8d6d-82b8-614a-1c8cb0f8dcc6',
    cmdTo: '61080002-8d6d-82b8-614a-1c8cb0f8dcc6',
    cmdFrom: '61080003-8d6d-82b8-614a-1c8cb0f8dcc6',
    events: '61080004-8d6d-82b8-614a-1c8cb0f8dcc6',
    data: '61080005-8d6d-82b8-614a-1c8cb0f8dcc6',
    memfault: '61080007-8d6d-82b8-614a-1c8cb0f8dcc6',
  );

  /// WHOOP 5 — base `fd4b000x-cce1-4033-93ce-002d5875f58a`.
  static const GattProfile gen5 = GattProfile(
    service: 'fd4b0001-cce1-4033-93ce-002d5875f58a',
    cmdTo: 'fd4b0002-cce1-4033-93ce-002d5875f58a',
    cmdFrom: 'fd4b0003-cce1-4033-93ce-002d5875f58a',
    events: 'fd4b0004-cce1-4033-93ce-002d5875f58a',
    data: 'fd4b0005-cce1-4033-93ce-002d5875f58a',
    memfault: 'fd4b0007-cce1-4033-93ce-002d5875f58a',
  );

  /// The service-UUID 32-bit prefix used to identify this generation from a
  /// scan result (case-insensitive `startsWith`).
  String get servicePrefix => service.substring(0, 8);
}

/// Per-generation frame wire-format profile. Immutable; use the [gen4] / [gen5]
/// singletons or [BandProfile.of].
class BandProfile {
  final DeviceType type;

  /// Header length in bytes before the inner payload (gen4 = 4, gen5 = 8).
  final int headerLen;

  /// Byte offset of the u16-LE declared-length field within the header
  /// (gen4 = 1, gen5 = 2). `declared` counts the padded inner + 4-byte CRC32.
  final int sizeFieldOffset;

  /// gen5 header bytes[4:6] when WE are the sender of a COMMAND-type frame
  /// (host → strap). Null on gen4, which has no such field at all (4-byte
  /// header).
  ///
  /// FINDING (byte-verified against 8 real gen5 fixtures, not stated
  /// correctly by either upstream reference repo — both assumed a single
  /// universal `[0x00,0x01]`): these bytes are NOT a fixed constant. Every
  /// host→strap COMMAND frame carries `[0x00,0x01]`; every strap→host frame
  /// of every OTHER packet type (METADATA, HISTORICAL_DATA, REALTIME_DATA,
  /// EVENT, COMMAND_RESPONSE, CONSOLE_LOGS) carries `[0x01,0x00]` instead —
  /// it is a direction/session marker, not a magic validity constant. The
  /// CRC16 covers whichever bytes are actually there, so a wrong assumption
  /// here was never a CRC-validity bug, only a semantic one.
  ///
  /// [buildHeader] uses [outboundDirectionMarker] because every existing
  /// builder in this package constructs an outbound COMMAND frame. Nothing in
  /// this package gates *inbound*-frame validity on these bytes — do not add
  /// such a gate, or every real strap→host gen5 frame (i.e. almost
  /// everything a live BLE session receives) would be rejected.
  final List<int>? outboundDirectionMarker;

  /// gen5 header bytes[4:6] on a real strap→host frame of any packet type
  /// other than COMMAND. Documentation-only (no code path currently gates on
  /// it) — kept as profile data per the multiband port plan's Layer-1
  /// recommendation, so a future band's direction convention (if any) is data
  /// here, not a literal buried in framing/BLE code.
  final List<int>? inboundDirectionMarker;

  const BandProfile._(
    this.type,
    this.headerLen,
    this.sizeFieldOffset, {
    this.outboundDirectionMarker,
    this.inboundDirectionMarker,
  });

  static const BandProfile gen4 = BandProfile._(DeviceType.gen4, 4, 1);
  static const BandProfile gen5 = BandProfile._(
    DeviceType.gen5,
    8,
    2,
    outboundDirectionMarker: [0x00, 0x01],
    inboundDirectionMarker: [0x01, 0x00],
  );

  static BandProfile of(DeviceType t) => t == DeviceType.gen5 ? gen5 : gen4;

  bool get isGen5 => type == DeviceType.gen5;

  /// GATT UUIDs for this generation.
  GattProfile get gatt => isGen5 ? GattProfile.gen5 : GattProfile.gen4;

  /// Read the declared length (padded inner + CRC32) from a frame's header.
  /// Caller must ensure `frame.length >= sizeFieldOffset + 2`.
  int declaredLen(List<int> frame) =>
      frame[sizeFieldOffset] | (frame[sizeFieldOffset + 1] << 8);

  /// Total frame length on the wire for a given declared length.
  int totalLen(int declared) => headerLen + declared;

  /// Validate the header integrity check. gen4 = crc8 over the 2 length bytes
  /// at frame[3]; gen5 = crc16-modbus over frame[0:6] at frame[6:8] LE.
  bool headerCrcValid(List<int> frame) {
    if (!isGen5) {
      if (frame.length < 4) return false;
      return frame[3] == crc8([frame[1], frame[2]]);
    }
    if (frame.length < 8) return false;
    final want = frame[6] | (frame[7] << 8);
    return crc16Modbus(frame.sublist(0, 6)) == want;
  }

  /// Build the frame header for a given declared length.
  ///   gen4: `[0xAA][u16 declared LE][crc8]`
  ///   gen5: `[0xAA][0x01][u16 declared LE][outboundDirectionMarker][crc16modbus LE]`
  ///
  /// Every builder in this package constructs an OUTBOUND (host→strap)
  /// COMMAND frame, so this always stamps [outboundDirectionMarker] — never
  /// use this to synthesize a frame representing something the strap sent us
  /// (see the field doc for why that byte pair differs by direction).
  Uint8List buildHeader(int declared) {
    if (!isGen5) {
      final h = Uint8List(4);
      h[0] = sof;
      h[1] = declared & 0xFF;
      h[2] = (declared >> 8) & 0xFF;
      h[3] = crc8([h[1], h[2]]);
      return h;
    }
    final h = Uint8List(8);
    h[0] = sof;
    h[1] = 0x01;
    h[2] = declared & 0xFF;
    h[3] = (declared >> 8) & 0xFF;
    final dir = outboundDirectionMarker ?? const [0x00, 0x01];
    h[4] = dir[0];
    h[5] = dir[1];
    final c = crc16Modbus(h.sublist(0, 6));
    h[6] = c & 0xFF;
    h[7] = (c >> 8) & 0xFF;
    return h;
  }
}
