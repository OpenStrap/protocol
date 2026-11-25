// The v24 record tail (inner[72:92]) — every structural claim in
// v24_status.dart, asserted against the real v24 records already in
// decode_parity_cases.json, plus hand-built records for the states that
// corpus does not contain (a measurement window, a clipped lane).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

List<Uint8List> _realV24Records() {
  final cases =
      json.decode(File('decode_parity_cases.json').readAsStringSync()) as List;
  final out = <Uint8List>[];
  for (final c in cases) {
    final hex = (c as Map)['hex'] as String;
    if (hex.length != 192) continue;
    final b = hexToBytes(hex);
    if (b[1] == 24) out.add(b);
  }
  return out;
}

int _counter(Uint8List b) => b.buffer
    .asByteData(b.offsetInBytes, b.lengthInBytes)
    .getUint32(3, Endian.little);

Uint8List _with(Uint8List base, Map<int, int> bytes) {
  final b = Uint8List.fromList(base);
  bytes.forEach((k, v) => b[k] = v);
  return b;
}

void main() {
  late final List<Uint8List> records;
  setUpAll(() {
    records = _realV24Records()..sort((a, b) => _counter(a) - _counter(b));
    // 1,887 entries; several decoder kinds reuse one frame, so fewer distinct.
    expect(records.length, 1887, reason: 'v24 entries in the corpus');
    expect({for (final b in records) b.join(',')}.length, 629);
  });

  group('v24 tail on the real corpus', () {
    test('every record decodes; the control words carry slot index 0/1/2', () {
      for (final b in records) {
        final s = parseV24Status(b);
        expect(s, isNotNull);
        expect([for (final w in s!.slots) w.slotIndex], [0, 1, 2]);
      }
    });

    test('slots 2 and 3 are off, slot 1 has a known drive value', () {
      for (final b in records) {
        final s = parseV24Status(b)!;
        expect(s.slots[1].configuredOff, isTrue);
        expect(s.slots[2].configuredOff, isTrue);
        expect(s.slotsConfiguredOn, isFalse);
        expect(s.measurementWindowByte, 0);
        expect(s.percentLikeValue, isNull);
        expect(s.slots[0].configuredOff, isFalse);
        expect(s.slots[0].driveParam, isIn([2200, 3350]));
        expect(v24NextSlot1Descriptor(s.slots[0])!.length, 25);
      }
    });

    test('the step-like counter never decreases across 8 h of records', () {
      var prev = -1;
      for (final b in records) {
        final v = parseV24Status(b)!.stepLikeCounter;
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
      expect(parseV24Status(records.first)!.stepLikeCounter, 3153);
      expect(parseV24Status(records.last)!.stepLikeCounter, 6248);
    });

    test('the temperature candidate stays in 348-354', () {
      for (final b in records) {
        final t = parseV24Status(b)!.temperatureCandidateRaw;
        expect(t, inInclusiveRange(348, 354));
      }
    });

    test('the activity state is the same two bits as inner[30] bits 5-6', () {
      for (final b in records) {
        final s = parseV24Status(b)!;
        expect(s.activityState.index, (b[30] >> 5) & 3);
      }
    });

    test('the motion byte is zero in every STILL record', () {
      var still = 0;
      for (final b in records) {
        final s = parseV24Status(b)!;
        if (s.activityState == V24ActivityState.still) {
          still++;
          expect(s.motionByte, 0);
        }
      }
      expect(still, 237);
    });
  });

  group('v24 tail — states the corpus does not contain', () {
    test('slots 2 and 3 configured on', () {
      // Drive codes 11/6: live R11 showed slot 2 drive 12750 and slot 3 drive
      // 4250 for them. The lane codes here are edited in.
      final b = _with(records.first, {76: 0x01, 77: 0x0b, 78: 0x92, 79: 0x06});
      final s = parseV24Status(_with(b, {82: 97}))!;
      expect(s.slotsConfiguredOn, isTrue);
      expect(s.slots[1].driveParam, 12750);
      expect(s.slots[2].driveParam, 4250);
      expect(s.slots[2].laneAParam, 800);
      expect(s.slots[2].laneBParam, 1600);
      expect(s.percentLikeValue, 97);
      // Only 77-100 counts; the raw byte is always kept.
      for (final v in [0, 76, 101, 160]) {
        final o = parseV24Status(_with(b, {82: v}))!;
        expect(o.percentLikeValue, isNull);
        expect(o.measurementWindowByte, v);
      }
      for (final v in [77, 100]) {
        expect(parseV24Status(_with(b, {82: v}))!.percentLikeValue, v);
      }
    });

    test('percentLikeValue fails closed for every drive pair but 11/6', () {
      for (var c2 = 0; c2 < 16; c2++) {
        for (var c3 = 0; c3 < 16; c3++) {
          final s = parseV24Status(
              _with(records.first, {77: c2, 79: c3, 82: 97}))!;
          expect(s.percentLikeValue, c2 == 11 && c3 == 6 ? 97 : isNull,
              reason: '$c2/$c3');
          expect(s.measurementWindowByte, 97);
          expect(s.slotsConfiguredOn, c2 != 12 && c3 != 12);
        }
      }
    });

    test('single-byte fields come from their own offsets', () {
      final s = parseV24Status(
          _with(records.first, {82: 11, 84: 22, 85: 33, 86: 44, 87: 55}))!;
      expect(
          [s.measurementWindowByte, s.motionByte, s.sessionClassByte],
          [11, 33, 55]);
    });

    test('drive tables are per slot', () {
      for (var c = 0; c < 16; c++) {
        final s = parseV24Status(_with(records.first, {77: c, 79: c}))!;
        expect(s.slots[1].driveParam, const {11: 12750}[c], reason: 'slot 2');
        expect(s.slots[2].driveParam, const {6: 4250, 10: 10300}[c],
            reason: 'slot 3');
      }
    });

    test('clip flags are per lane', () {
      final a = parseV24Status(_with(records.first, {75: 0x16}))!.slots[0];
      expect([a.laneAClipped, a.laneBClipped], [true, false]);
      final b = parseV24Status(_with(records.first, {75: 0x46}))!.slots[0];
      expect([b.laneAClipped, b.laneBClipped], [false, true]);
    });

    test('slot-1 descriptor and clip flags', () {
      // 0x90 = lane A code 1, lane B code 2; 0x56 = drive code 6 + flags
      // 0x10 (lane A at the ADC ceiling) and 0x40 (lane B).
      final s = parseV24Status(_with(records.first, {74: 0x90, 75: 0x56}))!;
      expect(s.slots[0].laneAClipped, isTrue);
      expect(s.slots[0].laneBClipped, isTrue);
      expect(
        v24NextSlot1Descriptor(s.slots[0]),
        hexToBytes('0032047e04057e04017e04042000000020030520000000'
            '4006'),
      );
    });

    test('an unseen drive code is unknown, not interpolated', () {
      final s = parseV24Status(_with(records.first, {75: 0x04}))!;
      expect(s.slots[0].driveParam, isNull);
      expect(v24NextSlot1Descriptor(s.slots[0]), isNull);
    });

    test('not a v24 tail: wrong version, short, or broken slot indices', () {
      expect(parseV24Status(_with(records.first, {1: 25})), isNull);
      expect(
          parseV24Status(Uint8List.sublistView(records.first, 0, 95)), isNull);
      expect(parseV24Status(records.first), isNotNull);
      expect(
          parseV24Status(Uint8List.fromList([...records.first, 0])), isNull);
      expect(parseV24Status(_with(records.first, {76: 0x00})), isNull);
    });
  });
}
