// A 1,584-byte framed R16 does not fit one BLE notification. The official
// history sync only counts it once complete WHOOP-frame reassembly has run
// (docs/mg/05 §"Required conformance fixtures" item 3). These tests feed one
// synthetic R16 frame — and a small R18 behind it — through the gen5
// FrameReassembler under adversarial chunkings, including a body that
// contains 0xAA bytes and a fake `aa 01` header.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

Uint8List r16Frame() {
  final inner = Uint8List(LabradorR16Raw.observedInnerLen);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2F;
  inner[1] = 16;
  inner[2] = 3;
  v.setUint32(3, 24016883, Endian.little);
  v.setUint32(7, 1787928472, Endian.little);
  v.setUint16(11, 19334, Endian.little);
  for (var i = 13; i < inner.length; i++) {
    inner[i] = (i * 13 + 5) & 0xff;
  }
  // Plant an SOF byte and a plausible fake gen5 header inside the body: a
  // "reset on 0xAA" reassembler would resync on it and lose the frame.
  inner[300] = 0xAA;
  inner[301] = 0x01;
  inner[302] = 0x10;
  inner[303] = 0x00;
  return buildFrame(inner, profile: BandProfile.gen5);
}

Uint8List smallR18Frame() {
  final inner = Uint8List(kGen5V18InnerLen);
  inner[0] = 0x2F;
  inner[1] = 18;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 24016884, Endian.little);
  v.setUint32(7, 1787928473, Endian.little);
  inner[14] = 60; // plausible HR so the v18 decoder is happy if consulted
  return buildFrame(inner, profile: BandProfile.gen5);
}

List<Frame> feedChunks(List<int> stream, int chunk) {
  final asm = FrameReassembler(profile: BandProfile.gen5);
  final out = <Frame>[];
  for (var i = 0; i < stream.length; i += chunk) {
    final end = i + chunk > stream.length ? stream.length : i + chunk;
    out.addAll(asm.feed(stream.sublist(i, end)));
  }
  return out;
}

void main() {
  final frame = r16Frame();

  test('the synthetic R16 frame has the physically observed size', () {
    expect(frame, hasLength(LabradorR16Raw.observedFrameLen));
  });

  for (final chunk in [1, 7, 20, 244, 512, 1583, 1584, 4096]) {
    test('one R16 frame survives $chunk-byte chunking', () {
      final frames = feedChunks(frame, chunk);
      expect(frames, hasLength(1));
      final f = frames.single;
      expect(f.decodable, isTrue);
      expect(f.inner, hasLength(LabradorR16Raw.observedInnerLen));
      final r = LabradorR16Raw.tryParseFrame(f)!;
      expect(r.sequence, 24016883);
      expect(r.strapSeconds, 1787928472);
      expect(r.subseconds, 19334);
    });
  }

  test('a chunk boundary exactly after the header, and one inside the CRC32',
      () {
    final asm = FrameReassembler(profile: BandProfile.gen5);
    final out = <Frame>[];
    out.addAll(asm.feed(frame.sublist(0, 8)));
    expect(out, isEmpty);
    out.addAll(asm.feed(frame.sublist(8, frame.length - 2)));
    expect(out, isEmpty, reason: 'two CRC bytes still outstanding');
    out.addAll(asm.feed(frame.sublist(frame.length - 2)));
    expect(out, hasLength(1));
    expect(out.single.decodable, isTrue);
  });

  test('a chunk boundary landing on the embedded fake 0xAA header', () {
    final asm = FrameReassembler(profile: BandProfile.gen5);
    final split = 8 + 300; // the planted SOF sits at inner[300]
    final out = <Frame>[
      ...asm.feed(frame.sublist(0, split)),
      ...asm.feed(frame.sublist(split)),
    ];
    expect(out, hasLength(1));
    expect(LabradorR16Raw.tryParseFrame(out.single), isNotNull);
  });

  test('an R16 followed by a small R18 in one stream yields both, in order',
      () {
    final stream = [...frame, ...smallR18Frame()];
    for (final chunk in [1, 20, 244, 5000]) {
      final frames = feedChunks(stream, chunk);
      expect(frames, hasLength(2), reason: 'chunk $chunk');
      expect(frames[0].inner[1], 16);
      expect(frames[1].inner[1], 18);
      expect(frames.every((f) => f.decodable), isTrue);
    }
  });
}
