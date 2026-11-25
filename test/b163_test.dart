// sect163r2 (B-163) ECDH known-value tests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

Uint8List unhex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/fixtures/huami2021_vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final ecdh = v['ecdh'] as Map<String, dynamic>;

  test('private key masking clears bits 163 and above', () {
    final privAIn = unhex(ecdh['privA_in'] as String);
    final kp = keypairFrom(privAIn);
    expect(hex(kp.privateKey), ecdh['privA']);
  });

  test('public key derivation matches known value, both sides', () {
    final kpA = keypairFrom(unhex(ecdh['privA_in'] as String));
    expect(hex(kpA.publicKey), ecdh['pubA']);
    final kpB = keypairFrom(unhex(ecdh['privB_in'] as String));
    expect(hex(kpB.publicKey), ecdh['pubB']);
  });

  test('shared secret matches from both sides, and agrees', () {
    final privA = unhex(ecdh['privA'] as String);
    final privB = unhex(ecdh['privB'] as String);
    final pubA = unhex(ecdh['pubA'] as String);
    final pubB = unhex(ecdh['pubB'] as String);
    // The fixture's 'shared' is the full 48-byte point (X||Y); the protocol
    // uses only the X half (first 24 bytes).
    final fullShared = ecdh['shared'] as String;
    final expectedX = fullShared.substring(0, 48);
    final sharedFromA = sharedSecret(privA, pubB);
    final sharedFromB = sharedSecret(privB, pubA);
    expect(hex(sharedFromA), expectedX);
    expect(hex(sharedFromB), expectedX);
  });

  test('a corrupted peer public key is rejected, not silently accepted', () {
    final priv = unhex(ecdh['privA'] as String);
    final badPub = Uint8List.fromList(unhex(ecdh['pubB'] as String));
    badPub[0] ^= 0xff;
    expect(() => sharedSecret(priv, badPub), throwsA(isA<B163Error>()));
  });
}
