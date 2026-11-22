// Huami2021/ZeppOS auth handshake (endpoint 0x0082) known-value tests.
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

Uint8List _aesEcb(Uint8List key, Uint8List data) {
  final c = ECBBlockCipher(AESEngine())..init(true, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

void main() {
  final v = jsonDecode(File('test/fixtures/huami2021_vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final ecdh = v['ecdh'] as Map<String, dynamic>;
  final auth = v['auth'] as Map<String, dynamic>;

  // Our side uses ecdh.privA/pubA; the device's reply carries ecdh.pubB as
  // its public key, so the derived shared secret matches ecdh.shared.
  B163Keypair ourKeypair() => B163Keypair(
      unhex(ecdh['privA'] as String), unhex(ecdh['pubA'] as String));

  Uint8List step2Reply() => Uint8List.fromList([
        0x10, 0x04, 0x01,
        ...unhex(auth['remoteRandom'] as String),
        ...unhex(ecdh['pubB'] as String),
      ]);

  test('step 1 payload is 04 02 00 02 followed by our public key', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    final payload = hs.start();
    expect(hex(payload.sublist(0, 4)), '04020002');
    expect(hex(payload.sublist(4)), ecdh['pubA']);
  });

  test('step 2 reply yields the known proof, sequence and session key', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    hs.start();
    final event = hs.onPayload(step2Reply());
    final proof = (event as Huami2021AuthSendProof).payload;
    expect(hex(proof), auth['proof']);
  });

  test('step 5 success yields the known session key and sequence', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    hs.start();
    hs.onPayload(step2Reply());
    final event = hs.onPayload(Uint8List.fromList([0x10, 0x05, 0x01]));
    final done = event as Huami2021Authenticated;
    expect(hex(done.sessionKey), auth['sessionKey']);
    expect(done.sequence, auth['sequence']);
  });

  test('status 0x25 on step 5 reports WrongAuthKey', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    hs.start();
    hs.onPayload(step2Reply());
    final event = hs.onPayload(Uint8List.fromList([0x10, 0x05, 0x25]));
    final failed = (event as Huami2021AuthFailed).failure;
    expect(failed, isA<WrongAuthKey>());
  });

  test('a non-success status on step 2 is reported, not retried silently', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    hs.start();
    final event = hs.onPayload(Uint8List.fromList([0x10, 0x04, 0x02]));
    final failed = (event as Huami2021AuthFailed).failure as AuthRejected;
    expect(failed.step, 2);
    expect(failed.status, 2);
  });

  test('an unrelated payload before the handshake starts is ignored', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    expect(hs.onPayload(Uint8List.fromList([0x01, 0x02])),
        isA<Huami2021AuthIgnored>());
  });

  test('starting twice throws', () {
    final hs = Huami2021Auth(unhex(auth['authKey'] as String),
        aesEcb: _aesEcb, keypair: ourKeypair());
    hs.start();
    expect(() => hs.start(), throwsStateError);
  });

  test('a 15-byte auth key is rejected at construction', () {
    expect(
        () => Huami2021Auth(Uint8List(15), aesEcb: _aesEcb),
        throwsArgumentError);
  });
}
