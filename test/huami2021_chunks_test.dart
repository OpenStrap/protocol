// Huami2021 chunk transport known-value tests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, ECBBlockCipher, KeyParameter;
import 'package:test/test.dart';

Uint8List unhex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List _aes(Uint8List key, Uint8List data, bool enc) {
  final c = ECBBlockCipher(AESEngine())..init(enc, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

Uint8List aesEnc(Uint8List k, Uint8List d) => _aes(k, d, true);
Uint8List aesDec(Uint8List k, Uint8List d) => _aes(k, d, false);

void main() {
  final v = jsonDecode(File('test/fixtures/huami2021_vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final chunks = v['chunks'] as Map<String, dynamic>;

  void expectEncodes(Map<String, dynamic> m, Huami2021Encoder enc,
      {bool encrypt = false}) {
    final got = enc.encode(m['endpoint'] as int, unhex(m['payload'] as String),
        encrypt: encrypt);
    expect(got.map(hex).toList(), (m['chunks'] as List).cast<String>());
  }

  test('first chunk header: marker, flags, handle, count, length, endpoint', () {
    final c = Huami2021Encoder().encode(0x0016, [0x03]).single;
    expect(hex(c), '030700010001000000160003');
  });

  test('handle increments per message and wraps', () {
    final enc = Huami2021Encoder();
    for (var i = 0; i < 254; i++) {
      enc.encode(1, [1]);
    }
    expect(enc.encode(1, [1]).single[3], 0xFF);
    expect(enc.encode(1, [1]).single[3], 0x00);
  });

  test('ack layout', () => expect(hex(huami2021Ack(5, 3)), '0400050103'));

  test('plain framing matches known-value vectors at MTU 247 and 23', () {
    final shared = Huami2021Encoder(mtu: 247); // generator reused one encoder
    Map<String, dynamic> m(String k) => chunks[k] as Map<String, dynamic>;
    expectEncodes(m('plain_short'), shared);
    expectEncodes(m('plain_long'), shared);
    expectEncodes(m('plain_tiny'), Huami2021Encoder(mtu: 23));
  });

  test('encrypted framing matches known-value vectors, and decodes', () {
    final e = chunks['encrypted'] as Map<String, dynamic>;
    final key = unhex(e['sessionKey'] as String);
    final enc = Huami2021Encoder(encrypt: aesEnc)
      ..setEncryption(key, e['sequence'] as int);
    final msgs = (e['messages'] as List).cast<Map<String, dynamic>>();
    for (final m in msgs) {
      expectEncodes(m, enc, encrypt: true);
    }
    final dec = Huami2021Decoder(decrypt: aesDec);
    Huami2021Frame? f;
    for (final c in (msgs[1]['chunks'] as List).cast<String>()) {
      f = dec.feed(unhex(c), sessionKey: key);
    }
    expect(hex(f!.payload), msgs[1]['payload']);
    expect(f.encrypted, isTrue);
  });

  test('encrypted frame without a session key yields no frame', () {
    final key = Uint8List(16);
    final enc = Huami2021Encoder(encrypt: aesEnc)..setEncryption(key, 0);
    final c = enc.encode(1, [1, 2], encrypt: true).single;
    expect(Huami2021Decoder(decrypt: aesDec).feed(c), isNull);
  });

  test('round trip, 100 bytes over several chunks', () {
    final key = Uint8List.fromList([for (var i = 0; i < 16; i++) i * 9]);
    final enc = Huami2021Encoder(mtu: 40, encrypt: aesEnc)..setEncryption(key, 7);
    final payload = Uint8List.fromList([for (var i = 0; i < 100; i++) i]);
    final cs = enc.encode(0x0047, payload, encrypt: true);
    expect(cs.length, greaterThan(1));
    final dec = Huami2021Decoder(decrypt: aesDec);
    Huami2021Frame? f;
    for (final c in cs) {
      f = dec.feed(c, sessionKey: key);
    }
    expect(f!.payload, payload);
    expect(f.endpoint, 0x0047);
    expect(f.needsAck, isTrue);
  });

  test('an orphan chunk with no preceding first chunk is rejected, not an '
      'empty frame on endpoint 0', () {
    final enc = Huami2021Encoder(mtu: 40);
    final payload = Uint8List.fromList([for (var i = 0; i < 100; i++) i]);
    final cs = enc.encode(7, payload);
    expect(cs.length, greaterThan(1));
    // Feed only the LAST chunk — no first chunk was ever seen.
    expect(Huami2021Decoder().feed(cs.last), isNull);
  });

  test('a dropped middle chunk is rejected, not a silently truncated '
      'payload', () {
    final enc = Huami2021Encoder(mtu: 40);
    final payload = Uint8List.fromList([for (var i = 0; i < 100; i++) i]);
    final cs = enc.encode(7, payload);
    expect(cs.length, greaterThan(2), reason: 'need at least 3 chunks to drop a middle one');
    final dec = Huami2021Decoder();
    expect(dec.feed(cs[0]), isNull); // first chunk: no frame yet
    // Skip cs[1] — simulate a dropped middle chunk — then feed the rest.
    for (var i = 2; i < cs.length; i++) {
      final f = dec.feed(cs[i]);
      if (i < cs.length - 1) {
        expect(f, isNull);
      } else {
        expect(f, isNull, reason: 'the gap must be rejected, not reassembled');
      }
    }
  });

  test('a repeated chunk (duplicate count) is rejected', () {
    final enc = Huami2021Encoder(mtu: 40);
    final payload = Uint8List.fromList([for (var i = 0; i < 100; i++) i]);
    final cs = enc.encode(7, payload);
    expect(cs.length, greaterThan(2));
    final dec = Huami2021Decoder();
    expect(dec.feed(cs[0]), isNull);
    expect(dec.feed(cs[1]), isNull);
    expect(dec.feed(cs[1]), isNull); // repeated, not the real cs[2]
  });

  test('a wrong session key decrypts to garbage that the CRC check catches, '
      'yielding null rather than a corrupted frame', () {
    final rightKey = Uint8List.fromList([for (var i = 0; i < 16; i++) i * 9]);
    final wrongKey = Uint8List.fromList([for (var i = 0; i < 16; i++) i * 7 + 1]);
    final enc = Huami2021Encoder(encrypt: aesEnc)..setEncryption(rightKey, 1);
    final payload = Uint8List.fromList([for (var i = 0; i < 20; i++) i]);
    final chunk = enc.encode(9, payload, encrypt: true).single;
    final dec = Huami2021Decoder(decrypt: aesDec);
    expect(dec.feed(chunk, sessionKey: wrongKey), isNull);
  });
}
