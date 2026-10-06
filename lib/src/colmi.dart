// Colmi smart ring family (R02/R03/R06/R07/R09/R10/R12 and siblings): the
// wire format, request builders and history decoders.
//
// TWO CHANNELS ON ONE RING.
//  * Service A (6e40fff0…): fixed 16-byte frames, `[cmd][payload x14][sum]`,
//    where `sum` is the low byte of bytes 0-14. Battery, clock, and the paged
//    HR / stress / HRV / activity history walks live here.
//  * Service B (de5bf728…): "big data", `[0xbc][type][u16 len][u16 crc]
//    [payload]`, crc = CRC-16/MODBUS of the payload, all little-endian. A
//    reply larger than one notification is split across several and has to
//    be reassembled ([ColmiBigDataReassembler]). Sleep, SpO2 and temperature
//    history live here. Whether the ring fills a REPLY's crc the same way is
//    unverified, so [colmiBigDataCrcOk] is a check to log, not to drop on.
//
// NO HANDSHAKE, NO KEY. Connect, subscribe, write.
//
// TIME IS LOCAL WALL CLOCK, NOT UTC. The ring keeps the wall-clock time the
// host last set (BCD, no zone), and every history reply is relative to a
// local calendar day: "N days ago" plus a minute-of-day. This file never turns
// either into an epoch — it has no zone to do it with. Decoders return
// `daysAgo` + `minuteOfDay` and the host resolves them against its own local
// calendar, which is the only place a DST day can be handled correctly.
//
// VALUES ARE THE RING'S OWN. Stress, HRV, SpO2 and temperature are numbers the
// ring computed with methods nobody outside the vendor can describe. They are
// decoded faithfully here; what a consumer is allowed to do with them is not
// this file's call.

import 'crc.dart' show crc16Modbus;

// ── Service A opcodes ────────────────────────────────────────────────────────

const int kColmiCmdSetTime = 0x01;
const int kColmiCmdBattery = 0x03;
const int kColmiCmdReboot = 0x08;
const int kColmiCmdHrHistory = 0x15;
const int kColmiCmdStressHistory = 0x37;
const int kColmiCmdHrvHistory = 0x39;
const int kColmiCmdActivityHistory = 0x43;

/// Per-day sleep detail on Service A, for a ring whose SetTime reply says it
/// does not speak the big-data sleep protocol (see [colmiNewSleepProtocol]).
const int kColmiCmdSleepDetails = 0x44;
const int kColmiCmdFactoryReset = 0xff;

/// The ring answers a request it rejects with the request's id OR'd with this.
const int kColmiErrorFlag = 0x80;

/// Service A commands this host must never send: a reboot or a factory reset
/// (which wipes every stored day).
const Set<int> kColmiDestructiveCmds = {kColmiCmdReboot, kColmiCmdFactoryReset};

/// True when [frame] is a Service A frame carrying a destructive command.
bool colmiIsDestructive(List<int> frame) =>
    frame.isNotEmpty && kColmiDestructiveCmds.contains(frame[0] & 0xff);

// ── Service B ────────────────────────────────────────────────────────────────

const int kColmiCmdBigData = 0xbc;
const int kColmiBigTemperature = 0x25;
const int kColmiBigSleep = 0x27;
const int kColmiBigSpo2 = 0x2a;

/// Daytime naps. Same day-record layout as [kColmiBigSleep]; a ring that
/// records naps sends this as a second reply after the sleep reply.
const int kColmiBigNap = 0x3e;

/// `[0xbc][type][u16 len][u16 crc]` — the fixed part before the payload.
const int kColmiBigHeaderLength = 6;

/// Sleep stage codes as the ring sends them.
const int kColmiStageLight = 0x02;
const int kColmiStageDeep = 0x03;
const int kColmiStageRem = 0x04;
const int kColmiStageAwake = 0x05;

/// The one-byte page index that means "nothing stored for this request".
const int kColmiNoData = 0xff;

// ── Framing ──────────────────────────────────────────────────────────────────

/// One 16-byte Service A frame: `[cmd][payload, zero-padded to 14][sum]`.
List<int> colmiFrame(int cmd, [List<int> payload = const <int>[]]) {
  if (payload.length > 14) {
    throw ArgumentError('Colmi payload is at most 14 bytes, got '
        '${payload.length}');
  }
  final f = List<int>.filled(16, 0);
  f[0] = cmd & 0xff;
  for (var i = 0; i < payload.length; i++) {
    f[1 + i] = payload[i] & 0xff;
  }
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    sum += f[i];
  }
  f[15] = sum & 0xff;
  return f;
}

/// True when [f] is a well-formed Service A frame (length and checksum).
bool colmiFrameValid(List<int> f) {
  if (f.length != 16) return false;
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    sum += f[i];
  }
  return (sum & 0xff) == f[15];
}

/// One Service B request: `[0xbc][type][u16 len][u16 crc16Modbus][payload]`.
List<int> colmiBigDataRequest(int type, List<int> payload) {
  final crc = crc16Modbus(payload);
  return <int>[
    kColmiCmdBigData,
    type & 0xff,
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    crc & 0xff,
    (crc >> 8) & 0xff,
    ...payload,
  ];
}

/// Sleep history: every night the ring still holds. The trailing 0x01 also
/// asks for naps, which a ring that records them sends as a separate
/// [kColmiBigNap] reply after the sleep reply.
List<int> colmiSleepRequest() =>
    colmiBigDataRequest(kColmiBigSleep, [0xff, 0x01]);

/// SpO2 history: hourly max/min for every day the ring still holds.
List<int> colmiSpo2Request() => colmiBigDataRequest(kColmiBigSpo2, [0xff]);

/// Temperature history (models with a skin-temperature sensor only).
/// [mode] 6 asks for every stored day, 2 for what is new since today was
/// last read, 0 for today only. The ring answers with one reply per day.
List<int> colmiTemperatureRequest([int mode = 6]) =>
    colmiBigDataRequest(kColmiBigTemperature, [mode & 0xff]);

/// Reassembles one Service B reply split across notifications.
///
/// Feed every Service B notification in arrival order; [add] returns the
/// complete reply (header included) once `len + 6` bytes have arrived, else
/// null. A notification that does not start with 0xbc while nothing is
/// pending is not a reply this decoder understands and is dropped.
class ColmiBigDataReassembler {
  List<int>? _pending;
  int _want = 0;

  List<int>? add(List<int> chunk) {
    if (_pending == null) {
      if (chunk.length < kColmiBigHeaderLength ||
          chunk[0] != kColmiCmdBigData) {
        return null;
      }
      _want = kColmiBigHeaderLength + (chunk[2] | (chunk[3] << 8));
      _pending = <int>[];
    }
    _pending!.addAll(chunk);
    if (_pending!.length < _want) return null;
    final whole = _pending!.sublist(0, _want);
    _pending = null;
    return whole;
  }

  bool get pending => _pending != null;
}

/// True when a reassembled Service B reply's payload matches its CRC.
bool colmiBigDataCrcOk(List<int> reply) {
  if (reply.length < kColmiBigHeaderLength) return false;
  final len = reply[2] | (reply[3] << 8);
  if (reply.length < kColmiBigHeaderLength + len) return false;
  final crc = reply[4] | (reply[5] << 8);
  return crc16Modbus(
          reply.sublist(kColmiBigHeaderLength, kColmiBigHeaderLength + len)) ==
      crc;
}

// ── Service A requests ───────────────────────────────────────────────────────

int _bcd(int v) => ((v ~/ 10) << 4) | (v % 10);
int _unbcd(int b) => ((b >> 4) & 0x0f) * 10 + (b & 0x0f);

/// Set the ring's clock to a LOCAL wall-clock time, BCD-encoded, then the
/// ring's display [language] (0 = Simplified Chinese, 1 = English).
List<int> colmiSetTimeRequest(DateTime local, {int language = 1}) =>
    colmiFrame(kColmiCmdSetTime, [
      _bcd(local.year % 100),
      _bcd(local.month),
      _bcd(local.day),
      _bcd(local.hour),
      _bcd(local.minute),
      _bcd(local.second),
      language & 0xff,
    ]);

/// Whether the ring's SetTime reply says it serves sleep over the big-data
/// request ([colmiSleepRequest]); false means per-day [kColmiCmdSleepDetails]
/// on Service A. Null for a frame that is not a valid SetTime reply.
bool? colmiNewSleepProtocol(List<int> f) =>
    (colmiFrameValid(f) && f[0] == kColmiCmdSetTime) ? f[9] == 1 : null;

List<int> colmiBatteryRequest() => colmiFrame(kColmiCmdBattery);

/// Activity history for one local day, [daysAgo] = 0 for today.
List<int> colmiActivityRequest(int daysAgo) => colmiFrame(
    kColmiCmdActivityHistory, [daysAgo & 0xff, 0x0f, 0x00, 0x5f, 0x01]);

/// HR history from [localWallClockSec]: the LOCAL wall-clock instant written
/// as if it were UTC seconds (local midnight for a past day, now for today).
List<int> colmiHrHistoryRequest(int localWallClockSec) =>
    colmiFrame(kColmiCmdHrHistory, _u32le(localWallClockSec));

/// Stress history for one local day, [daysAgo] = 0 for today.
List<int> colmiStressRequest(int daysAgo) =>
    colmiFrame(kColmiCmdStressHistory, [daysAgo & 0xff]);

/// Service A sleep detail for one local day (0-29 days ago), every
/// quarter-hour slot of it (0x00-0x5f).
List<int> colmiSleepDetailsRequest(int daysAgo) =>
    colmiFrame(kColmiCmdSleepDetails, [daysAgo & 0xff, 0x0f, 0x00, 0x5f]);

/// HRV history for one local day.
List<int> colmiHrvRequest(int daysAgo) =>
    colmiFrame(kColmiCmdHrvHistory, _u32le(daysAgo));

List<int> _u32le(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

// ── Service A decoders ───────────────────────────────────────────────────────

/// Battery percentage from a battery reply, or null.
int? colmiBatteryPct(List<int> f) =>
    (colmiFrameValid(f) && f[0] == kColmiCmdBattery && f[1] <= 100)
        ? f[1]
        : null;

/// One time-of-day reading from a paged history walk.
class ColmiPoint {
  final int minuteOfDay;
  final int value;
  const ColmiPoint(this.minuteOfDay, this.value);
  @override
  String toString() => 'ColmiPoint($minuteOfDay, $value)';
}

/// Page 0 of a paged HR / stress / HRV walk: how many pages the walk has
/// (header included, so the last page is `pages - 1`) and the slot interval
/// in minutes. The HR interval is user-settable on the ring, so it is read
/// from here, never assumed.
typedef ColmiPagedHeader = ({int pages, int slotMinutes});

/// The page-0 header of a [cmd] walk, or null for any other frame. A zero
/// interval (never seen from a ring that measures) is left for the caller's
/// default.
ColmiPagedHeader? colmiPagedHeader(List<int> f, int cmd) {
  if (!colmiFrameValid(f) || f[0] != cmd || f[1] != 0) return null;
  return (pages: f[2], slotMinutes: f[3]);
}

/// The local wall-clock instant page 1 of an HR walk is stamped with, written
/// as if it were UTC seconds (the same convention as the request). Null for
/// any other frame, or a zero stamp.
int? colmiHrPageTimestamp(List<int> f) {
  if (!colmiFrameValid(f) || f[0] != kColmiCmdHrHistory || f[1] != 1) {
    return null;
  }
  final ts = f[2] | (f[3] << 8) | (f[4] << 16) | (f[5] << 24);
  return ts == 0 ? null : ts;
}

/// The day page 1 of a stress or HRV walk is for, as "days ago". Null for any
/// other frame.
int? colmiPagedDaysAgo(List<int> f) {
  if (!colmiFrameValid(f) ||
      (f[0] != kColmiCmdStressHistory && f[0] != kColmiCmdHrvHistory) ||
      f[1] != 1) {
    return null;
  }
  return f[2];
}

/// Shared paged layout of the HR, stress and HRV walks.
///
/// Page 0 is a header ([colmiPagedHeader]), page 0xff means "nothing
/// stored", and data pages follow. Page 1's values start at [firstStart] (the
/// bytes before it are header), every later page's at byte 2; each page
/// carries values up to byte 14 (byte 15 is the checksum). A zero value is an
/// unmeasured slot.
List<ColmiPoint> _pagedPoints(
  List<int> f, {
  required int cmd,
  required int firstStart,
  required int slotMinutes,
}) {
  if (!colmiFrameValid(f) || f[0] != cmd) return const [];
  final page = f[1];
  if (page == 0 || page == kColmiNoData || slotMinutes <= 0) return const [];
  final firstCount = 15 - firstStart;
  final start = page == 1 ? firstStart : 2;
  final before = page == 1 ? 0 : firstCount + (page - 2) * 13;
  final out = <ColmiPoint>[];
  for (var i = start; i < 15; i++) {
    final v = f[i];
    if (v == 0) continue;
    final minute = (before + (i - start)) * slotMinutes;
    if (minute >= 1440) break;
    out.add(ColmiPoint(minute, v));
  }
  return out;
}

/// HR history page: page 1 carries a 4-byte timestamp first. [slotMinutes]
/// comes from the walk's page 0; 5 is the ring's default.
List<ColmiPoint> colmiHrHistoryPoints(List<int> f, {int slotMinutes = 5}) =>
    _pagedPoints(f,
        cmd: kColmiCmdHrHistory, firstStart: 6, slotMinutes: slotMinutes);

/// Stress history page: the ring's own 0-100 score; page 1 carries the
/// day first. [slotMinutes] comes from page 0; 30 is the ring's default.
List<ColmiPoint> colmiStressPoints(List<int> f, {int slotMinutes = 30}) =>
    _pagedPoints(f,
        cmd: kColmiCmdStressHistory, firstStart: 3, slotMinutes: slotMinutes);

/// HRV history page: the ring's own value (ms); same layout as stress.
List<ColmiPoint> colmiHrvPoints(List<int> f, {int slotMinutes = 30}) =>
    _pagedPoints(f,
        cmd: kColmiCmdHrvHistory, firstStart: 3, slotMinutes: slotMinutes);

/// One 15-minute activity slot.
class ColmiActivitySlot {
  final int year, month, day;
  final int minuteOfDay;
  final int steps;

  /// Ring units, already multiplied by 10 when the walk's header said so
  /// (see [colmiActivityCaloriesX10]).
  final int calories;

  /// Raw ring units (believed metres); scale unconfirmed.
  final int distance;
  final int page, pages;
  const ColmiActivitySlot({
    required this.year,
    required this.month,
    required this.day,
    required this.minuteOfDay,
    required this.steps,
    required this.calories,
    required this.distance,
    required this.page,
    required this.pages,
  });

  bool get isLast => page >= pages - 1;
}

/// For the 0xf0 header frame that opens an activity walk: whether the walk's
/// calorie counters are in tenths, i.e. must be multiplied by 10 (header byte
/// 3 == 1). Null for any other frame.
bool? colmiActivityCaloriesX10(List<int> f) =>
    (colmiFrameValid(f) && f[0] == kColmiCmdActivityHistory && f[1] == 0xf0)
        ? f[3] == 1
        : null;

/// One activity reply, or null for a header / no-data / malformed frame.
///
/// Date bytes are BCD (`0x24 0x08 0x18` = 2024-08-18); byte 4 is the
/// quarter-hour slot of the day (0-95). [caloriesX10] is the walk header's
/// [colmiActivityCaloriesX10].
ColmiActivitySlot? colmiActivitySlot(List<int> f, {bool caloriesX10 = false}) {
  if (!colmiFrameValid(f) || f[0] != kColmiCmdActivityHistory) return null;
  if (f[1] == kColmiNoData || f[1] == 0xf0) return null;
  final slot = f[4];
  if (slot > 95) return null;
  final month = _unbcd(f[2]), day = _unbcd(f[3]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return ColmiActivitySlot(
    year: 2000 + _unbcd(f[1]),
    month: month,
    day: day,
    minuteOfDay: slot * 15,
    calories: (f[7] | (f[8] << 8)) * (caloriesX10 ? 10 : 1),
    steps: f[9] | (f[10] << 8),
    distance: f[11] | (f[12] << 8),
    page: f[5],
    pages: f[6],
  );
}

/// True when [f] ends an activity walk: "no data", or the last page.
bool colmiActivityDone(List<int> f) {
  if (!colmiFrameValid(f) || f[0] != kColmiCmdActivityHistory) return false;
  if (f[1] == kColmiNoData) return true;
  return colmiActivitySlot(f)?.isLast ?? false;
}

/// One row of a Service A sleep-detail walk ([colmiSleepDetailsRequest]).
///
/// UNVERIFIED: no capture from a ring on this protocol exists, and how the
/// seven quality bytes map to sleep stages is not known, so rows are decoded
/// and banked but never turned into a hypnogram.
class ColmiSleepDetailRow {
  final int year, month, day;

  /// Quarter-hour slot of the day the row starts at (0-95).
  final int timeIndex;

  /// The ring's seven raw sleep-quality bytes for this row.
  final List<int> qualities;
  final int page, pages;
  const ColmiSleepDetailRow({
    required this.year,
    required this.month,
    required this.day,
    required this.timeIndex,
    required this.qualities,
    required this.page,
    required this.pages,
  });
}

/// One sleep-detail reply, or null for the 0xf0 header, "no data" (0xff) or
/// a malformed frame. Date bytes are BCD, as in the activity walk.
ColmiSleepDetailRow? colmiSleepDetailRow(List<int> f) {
  if (!colmiFrameValid(f) || f[0] != kColmiCmdSleepDetails) return null;
  if (f[1] == kColmiNoData || f[1] == 0xf0) return null;
  final month = _unbcd(f[2]), day = _unbcd(f[3]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return ColmiSleepDetailRow(
    year: 2000 + _unbcd(f[1]),
    month: month,
    day: day,
    timeIndex: f[4],
    page: f[5],
    pages: f[6],
    qualities: f.sublist(7, 14),
  );
}

/// True when [f] ends a sleep-detail walk: "no data", or the last row.
bool colmiSleepDetailsDone(List<int> f) {
  if (!colmiFrameValid(f) || f[0] != kColmiCmdSleepDetails) return false;
  if (f[1] == kColmiNoData) return true;
  final r = colmiSleepDetailRow(f);
  return r != null && r.page == r.pages - 1;
}

// ── Service B decoders ───────────────────────────────────────────────────────

/// One stage block of a night: [stage] for [minutes].
class ColmiStageBlock {
  final int stage;
  final int minutes;
  const ColmiStageBlock(this.stage, this.minutes);
}

/// One night (or, with [nap], one daytime nap) as the ring reports it.
/// [startMinute] and [endMinute] are minutes after LOCAL midnight of the day
/// [daysAgo]; a start greater than the end means the night began the evening
/// before.
///
/// For a night the end and the blocks are what to trust: the night starts
/// [totalMinutes] before [endMinute], which is how the ring's own data is
/// laid out, and the start field can disagree with it. A nap's blocks run
/// forward from its [startMinute], and a block of stage 0 is a gap between
/// naps rather than sleep.
class ColmiSleepNight {
  final int daysAgo;
  final int startMinute;
  final int endMinute;
  final List<ColmiStageBlock> blocks;
  final bool nap;
  const ColmiSleepNight(
      this.daysAgo, this.startMinute, this.endMinute, this.blocks,
      {this.nap = false});

  bool get startsDayBefore => startMinute > endMinute;

  /// Sum of every block's minutes.
  int get totalMinutes => blocks.fold(0, (s, b) => s + b.minutes);
}

/// Decodes a reassembled sleep ([kColmiBigSleep]) or nap ([kColmiBigNap])
/// reply. Malformed tails are dropped, never guessed.
List<ColmiSleepNight> colmiSleepNights(List<int> r) {
  if (r.length < kColmiBigHeaderLength + 1 ||
      r[0] != kColmiCmdBigData ||
      (r[1] != kColmiBigSleep && r[1] != kColmiBigNap)) {
    return const [];
  }
  final nap = r[1] == kColmiBigNap;
  final len = r[2] | (r[3] << 8);
  if (len < 2) return const [];
  final end = (kColmiBigHeaderLength + len).clamp(0, r.length);
  final nights = <ColmiSleepNight>[];
  final count = r[6];
  var i = 7;
  for (var n = 0; n < count; n++) {
    if (i + 6 > end) break;
    final daysAgo = r[i];
    final dayBytes = r[i + 1];
    final start = r[i + 2] | (r[i + 3] << 8);
    final stop = r[i + 4] | (r[i + 5] << 8);
    i += 6;
    final blockBytes = dayBytes - 4;
    if (blockBytes < 0 || i + blockBytes > end) break;
    final blocks = <ColmiStageBlock>[];
    for (var j = 0; j + 1 < blockBytes; j += 2) {
      final minutes = r[i + j + 1];
      if (minutes > 0) blocks.add(ColmiStageBlock(r[i + j], minutes));
    }
    i += blockBytes;
    if (start < 1440 && stop < 1440) {
      nights.add(ColmiSleepNight(daysAgo, start, stop, blocks, nap: nap));
    }
  }
  return nights;
}

/// One hour of SpO2: the ring's min and max reading in that hour.
class ColmiSpo2Hour {
  final int daysAgo;
  final int hour;
  final int min;
  final int max;
  const ColmiSpo2Hour(this.daysAgo, this.hour, this.min, this.max);
}

/// Bytes per SpO2 day block: `daysAgo` then 24 x (max, min).
const int kColmiSpo2DayBytes = 49;

/// Decodes a reassembled SpO2 reply: whole 49-byte day blocks, each a
/// `daysAgo` byte then 24 x (max, min). Blocks come in no promised order; a
/// partial trailing block is dropped.
List<ColmiSpo2Hour> colmiSpo2Hours(List<int> r) {
  if (r.length < kColmiBigHeaderLength ||
      r[0] != kColmiCmdBigData ||
      r[1] != kColmiBigSpo2) {
    return const [];
  }
  final end = (kColmiBigHeaderLength + (r[2] | (r[3] << 8))).clamp(0, r.length);
  final days = (end - kColmiBigHeaderLength) ~/ kColmiSpo2DayBytes;
  final out = <ColmiSpo2Hour>[];
  for (var d = 0; d < days; d++) {
    final b = kColmiBigHeaderLength + d * kColmiSpo2DayBytes;
    final daysAgo = r[b];
    for (var h = 0; h < 24; h++) {
      final hi = r[b + 1 + 2 * h], lo = r[b + 2 + 2 * h];
      if (lo > 0 && hi > 0 && lo <= 100 && hi <= 100) {
        out.add(ColmiSpo2Hour(daysAgo, h, lo, hi));
      }
    }
  }
  return out;
}

/// One skin-temperature reading, degrees Celsius.
class ColmiTemperature {
  final int daysAgo;
  final int minuteOfDay;
  final double celsius;
  const ColmiTemperature(this.daysAgo, this.minuteOfDay, this.celsius);
}

/// How a temperature reply's value bytes are encoded. FIRMWARE-DEPENDENT and
/// not announced anywhere on the wire, so it cannot be detected from a reply:
///  * [plus20]: one byte per slot, `byte / 10 + 20` degC, 0 = no reading.
///  * [runLengthPlus32]: a byte over 128 stands for `byte - 128` empty slots
///    in a row; any byte under 128 is one reading, `byte / 10 + 32` degC.
/// [plus20] is the default; the raw reply is always banked, so a ring that
/// turns out to speak the other form can be re-decoded.
enum ColmiTempEncoding { plus20, runLengthPlus32 }

/// Decodes ONE reassembled temperature reply, which carries one day:
/// `[daysAgo][timeSpan][values…]`, where slot k is the reading at minute
/// `k * timeSpan` and a day has `1440 / timeSpan` slots. A reply cut short
/// still yields the slots it has.
List<ColmiTemperature> colmiTemperatures(List<int> r,
    {ColmiTempEncoding encoding = ColmiTempEncoding.plus20}) {
  if (r.length < kColmiBigHeaderLength ||
      r[0] != kColmiCmdBigData ||
      r[1] != kColmiBigTemperature) {
    return const [];
  }
  final end =
      (kColmiBigHeaderLength + (r[2] | (r[3] << 8))).clamp(0, r.length);
  if (end - kColmiBigHeaderLength <= 2) return const [];
  final daysAgo = r[kColmiBigHeaderLength];
  final span = r[kColmiBigHeaderLength + 1];
  if (span == 0) return const [];
  final slots = 1440 ~/ span;
  final out = <ColmiTemperature>[];
  var k = 0;
  for (var i = kColmiBigHeaderLength + 2; i < end && k < slots; i++) {
    final b = r[i];
    if (encoding == ColmiTempEncoding.runLengthPlus32) {
      if (b > 128) {
        k += b - 128;
        continue;
      }
      // 0 is a real 32.0 degC here (empty slots are runs); 128 would decode
      // to 19.2 degC as a signed byte, which no skin reads, so it is skipped.
      if (b < 128) out.add(ColmiTemperature(daysAgo, k * span, b / 10 + 32));
    } else if (b > 0) {
      out.add(ColmiTemperature(daysAgo, k * span, b / 10 + 20));
    }
    k++;
  }
  return out;
}
