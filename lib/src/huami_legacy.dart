// Huami legacy activity history (Mi Band 2 and Mi Band 3): clock set, the
// paged activity fetch and the one-sample-per-minute record. Runs after the
// band's AES auth (which lives with the edge adapter).
//
// CLOCK — Current Time (0x2A2B), 11 bytes: year u16 LE, month, day, hour,
// minute, second, day of week (0 = Sunday … 6 = Saturday), milliseconds / 4,
// adjust reason (8 while daylight saving time is in effect, else 0), then the
// UTC offset (DST included) as a signed byte in 15-minute units.
//
// FETCH — on the activity-control characteristic (…0004):
//   host  `01 01 <year u16 LE, month, day, hour, minute> 00 <tz>`  start, since
//   band  `10 01 01 <u32 LE count> <year u16, mo, d, h, mi, s, tz>`  start ok;
//         count is the number of 4-byte minute samples, not bytes
//   host  `02`  send it
//   band  data on …0005: `[counter][payload]`, counter 0,1,2… wrapping; a
//         packet may be repeated verbatim, which is not a gap
//   band  `10 02 xx`  done (on the control characteristic)
// The next round starts at the header's time plus count minutes.
// The band's `03` acknowledgement tells it to DROP what it sent; nothing here
// builds it. Without it the band keeps its history and the host tracks its
// own resume point.
//
// SAMPLE — 4 bytes per minute: kind, intensity, steps, heart rate (0 and 0xFF
// mean no reading). Kind is the low nibble; 0 (no change) and 10 (ignore)
// inherit the previous minute's kind. Kinds: 1 activity, 2 running,
// 3 not worn, 4 cycling, 6 charging, 9 light sleep, 11 deep sleep, 12 woke up.

const String kHuamiActivityControlChar =
    '00000004-0000-3512-2118-0009af100700';
const String kHuamiActivityDataChar = '00000005-0000-3512-2118-0009af100700';

const int kHuamiKindNotWorn = 3;
const int kHuamiKindCharging = 6;
const int kHuamiKindLightSleep = 9;
const int kHuamiKindDeepSleep = 11;

int _tzQuarters(DateTime local) {
  final q = local.timeZoneOffset.inMinutes ~/ 15;
  return q & 0xff;
}

/// The band's clock value for [local].
List<int> huamiTimeValue(DateTime local) => [
      local.year & 0xff,
      local.year >> 8,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
      local.weekday % 7,
      local.millisecond ~/ 4,
      _inDst(local) ? 8 : 0,
      _tzQuarters(local),
    ];

/// Whether [local] is in daylight saving time: its offset is ahead of the
/// smaller of the January and July offsets of its year.
bool _inDst(DateTime local) {
  final jan = DateTime(local.year).timeZoneOffset;
  final jul = DateTime(local.year, 7).timeZoneOffset;
  return local.timeZoneOffset > (jan < jul ? jan : jul);
}

/// Start an activity fetch from [sinceLocal] (minute resolution).
List<int> huamiActivityFetchStart(DateTime sinceLocal) => [
      0x01,
      0x01,
      sinceLocal.year & 0xff,
      sinceLocal.year >> 8,
      sinceLocal.month,
      sinceLocal.day,
      sinceLocal.hour,
      sinceLocal.minute,
      0x00,
      _tzQuarters(sinceLocal),
    ];

/// "Send the data now".
const List<int> kHuamiActivityFetchData = [0x02];

/// Most minute samples one round can announce (90 days).
const int kHuamiMaxFetchCount = 129600;

/// The band's answer to a fetch start: how many minute samples it will send
/// and the instant of the first, or null when the start was refused or
/// announces an impossible count.
({int count, int startSec})? parseHuamiFetchStart(List<int> b) {
  if (b.length < 3 || b[0] != 0x10 || b[1] != 0x01 || b[2] != 0x01) {
    return null;
  }
  if (b.length < 7) return null;
  final count = b[3] | (b[4] << 8) | (b[5] << 16) | (b[6] << 24);
  if (count == 0) return (count: 0, startSec: 0);
  if (count > kHuamiMaxFetchCount) return null;
  if (b.length < 15) return null;
  final tz = b[14] >= 0x80 ? b[14] - 0x100 : b[14];
  final wall = DateTime.utc(b[7] | (b[8] << 8), b[9], b[10], b[11], b[12], b[13]);
  return (
    count: count,
    startSec: wall.millisecondsSinceEpoch ~/ 1000 - tz * 15 * 60,
  );
}

/// True when [b] (on the control characteristic) ends the data transfer.
bool huamiFetchDone(List<int> b) =>
    b.length >= 3 && b[0] == 0x10 && b[1] == 0x02;

/// One minute of activity.
class HuamiMinute {
  final int tsSec;
  final int kind;
  final int intensity;
  final int steps;

  /// Beats per minute, or null when the band took no reading.
  final int? hr;
  const HuamiMinute(this.tsSec, this.kind, this.intensity, this.steps, this.hr);

  bool get asleep => kind == kHuamiKindLightSleep || kind == kHuamiKindDeepSleep;
}

/// Reassembles one transfer's data packets. [ok] goes false on a counter gap —
/// the transfer is then not trustworthy and must not be decoded. An exact
/// repeat of the previous packet is dropped, not a gap.
class HuamiActivityBuffer {
  final List<int> bytes = [];
  int _next = 0;
  List<int>? _last;
  bool ok = true;

  void add(List<int> packet) {
    if (packet.isEmpty) return;
    final last = _last;
    if (last != null &&
        last.length == packet.length &&
        Iterable<int>.generate(packet.length)
            .every((i) => last[i] == packet[i])) {
      return;
    }
    if (packet[0] != (_next & 0xff)) ok = false;
    _next++;
    _last = List<int>.of(packet);
    bytes.addAll(packet.skip(1));
  }

  /// The minutes in this transfer, starting at [startSec]. A partial
  /// trailing sample is ignored.
  List<HuamiMinute> minutes(int startSec, {int previousKind = 1}) {
    final out = <HuamiMinute>[];
    var kind = previousKind;
    for (var i = 0; i + 4 <= bytes.length; i += 4) {
      final k = bytes[i] & 0x0f;
      if (k != 0 && k != 10) kind = k;
      final hr = bytes[i + 3];
      out.add(HuamiMinute(startSec + (i ~/ 4) * 60, kind, bytes[i + 1],
          bytes[i + 2], hr == 0 || hr == 0xff ? null : hr));
    }
    return out;
  }
}
