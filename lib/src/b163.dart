// Elliptic-curve Diffie-Hellman over the binary field GF(2^163), using the
// standard curve sect163r2 (SEC 2 / ANSI X9.62; also called NIST B-163):
// y^2 + xy = x^3 + x^2 + b over GF(2^163), reduction polynomial
// x^163 + x^7 + x^6 + x^3 + 1.
//
// Field elements are 163-bit binary polynomials, represented as six 32-bit
// little-endian words (192 bits of storage, top 29 bits always zero). A
// private key is 24 random bytes with bit 163 and above cleared; a public
// key is the 48-byte concatenation of the affine X and Y coordinates, each
// 24 bytes little-endian.

import 'dart:math';
import 'dart:typed_data';

/// One point's affine coordinates, or the point at infinity when [isInfinity].
class _Point {
  const _Point(this.x, this.y, {this.isInfinity = false});
  final Uint32List x;
  final Uint32List y;
  final bool isInfinity;

  static final _Point infinity =
      _Point(Uint32List(6), Uint32List(6), isInfinity: true);
}

class B163Keypair {
  const B163Keypair(this.privateKey, this.publicKey);

  /// 24 bytes, little-endian.
  final Uint8List privateKey;

  /// 48 bytes: X (24 bytes LE) followed by Y (24 bytes LE).
  final Uint8List publicKey;
}

/// Thrown when a supplied public key is not a valid point on the curve.
class B163Error extends ArgumentError {
  B163Error(super.message);
}

const int _words = 6;

// sect163r2 domain parameters, as 6 little-endian 32-bit words each.
final Uint32List _curveB = _fromWords(
    [0x4a3205fd, 0x512f7874, 0x1481eb10, 0xb8c953ca, 0x0a601907, 0x00000002]);
final Uint32List _baseX = _fromWords(
    [0xe8343e36, 0xd4994637, 0xa0991168, 0x86a2d57e, 0xf0eba162, 0x00000003]);
final Uint32List _baseY = _fromWords(
    [0x797324f1, 0xb11c5c0c, 0xa2cdd545, 0x71a0094f, 0xd51fbc6c, 0x00000000]);

Uint32List _fromWords(List<int> w) => Uint32List.fromList(w);

Uint32List _fromBytesLE(Uint8List b) {
  final out = Uint32List(_words);
  final bd = ByteData.sublistView(b);
  for (var i = 0; i < 6; i++) {
    final off = i * 4;
    out[i] = off + 4 <= b.length ? bd.getUint32(off, Endian.little) : 0;
  }
  return out;
}

Uint8List _toBytesLE(Uint32List w) {
  final out = Uint8List(24);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < 6; i++) {
    bd.setUint32(i * 4, w[i], Endian.little);
  }
  return out;
}

// Returns the index of the highest set bit, or -1 for the zero element.
int _highestBit(Uint32List a) {
  for (var w = _words - 1; w >= 0; w--) {
    if (a[w] != 0) return w * 32 + (31 - _clz32(a[w]));
  }
  return -1;
}

int _clz32(int v) {
  var n = 0;
  var x = v & 0xFFFFFFFF;
  if (x == 0) return 32;
  for (var bit = 31; bit >= 0; bit--) {
    if ((x >> bit) & 1 != 0) return 31 - bit;
    n++;
  }
  return n;
}

bool _isZero(Uint32List a) => a.every((w) => w == 0);

Uint32List _xor(Uint32List a, Uint32List b) {
  final out = Uint32List(_words);
  for (var i = 0; i < _words; i++) {
    out[i] = a[i] ^ b[i];
  }
  return out;
}

/// Binary-polynomial multiplication (no reduction), result up to 326 bits,
/// returned as a wider word array (12 words) for the reducer to consume.
Uint32List _polyMul(Uint32List a, Uint32List b) {
  final out = Uint32List(12);
  for (var i = 0; i < _words; i++) {
    if (a[i] == 0) continue;
    for (var bit = 0; bit < 32; bit++) {
      if ((a[i] >> bit) & 1 == 0) continue;
      final shift = i * 32 + bit;
      final wordShift = shift ~/ 32;
      final bitShift = shift % 32;
      for (var j = 0; j < _words; j++) {
        if (b[j] == 0) continue;
        final idx = wordShift + j;
        if (idx >= 12) continue;
        var v = b[j] << bitShift;
        out[idx] ^= v & 0xFFFFFFFF;
        if (bitShift != 0 && idx + 1 < 12) {
          out[idx + 1] ^= (b[j] >>> (32 - bitShift)) & 0xFFFFFFFF;
        }
      }
    }
  }
  return out;
}

/// Reduces a wide (up to 326-bit) product modulo x^163 + x^7 + x^6 + x^3 + 1.
Uint32List _reduce(Uint32List wide) {
  final w = Uint32List.fromList(wide);
  // Fold bits at or above 163 back in using the reduction relation
  // x^163 = x^7 + x^6 + x^3 + 1.
  for (var bit = 11 * 32 + 31; bit >= 163; bit--) {
    final word = bit ~/ 32;
    final off = bit % 32;
    if ((w[word] >> off) & 1 == 0) continue;
    w[word] ^= 1 << off;
    final reduceBy = bit - 163;
    for (final termShift in [0, 3, 6, 7]) {
      final target = reduceBy + termShift;
      final tw = target ~/ 32;
      final tb = target % 32;
      if (tw < w.length) w[tw] ^= 1 << tb;
    }
  }
  return Uint32List.fromList(w.sublist(0, _words));
}

Uint32List _mulMod(Uint32List a, Uint32List b) => _reduce(_polyMul(a, b));

Uint32List _sqrMod(Uint32List a) => _mulMod(a, a);

/// Multiplicative inverse mod the field polynomial: `a^-1 = a^(2^163 - 2)`,
/// since the field's multiplicative group has order `2^163 - 1`. Plain
/// left-to-right square-and-multiply over the exponent's 163 bits (bit 0 is
/// 0, bits 1..162 are 1) — a fixed-length loop, so it always terminates,
/// unlike a degree-tracking extended-Euclidean variant.
Uint32List _invert(Uint32List a) {
  if (_isZero(a)) throw B163Error('cannot invert zero');
  var result = Uint32List.fromList(_one);
  for (var bit = 162; bit >= 0; bit--) {
    result = _sqrMod(result);
    if (bit != 0) {
      result = _mulMod(result, a);
    }
  }
  return result;
}

_Point _pointAdd(_Point p, _Point q) {
  if (p.isInfinity) return q;
  if (q.isInfinity) return p;
  if (_eq(p.x, q.x)) {
    if (_isZero(p.x) || !_eq(p.y, q.y)) return _Point.infinity;
    return _pointDouble(p);
  }
  final lambda = _mulMod(_xor(p.y, q.y), _invert(_xor(p.x, q.x)));
  final lambdaSq = _sqrMod(lambda);
  final x3 = _xor(_xor(_xor(_xor(lambdaSq, lambda), p.x), q.x), _one);
  final y3 = _xor(
      _xor(_mulMod(lambda, _xor(p.x, x3)), x3), p.y);
  return _Point(x3, y3);
}

final Uint32List _one = _fromWords([1, 0, 0, 0, 0, 0]);

_Point _pointDouble(_Point p) {
  if (p.isInfinity || _isZero(p.x)) return _Point.infinity;
  // y^2 + xy = x^3 + x^2 + b (a2 = 1): x3 = lambda^2 + lambda + a2.
  final lambda = _xor(p.x, _mulMod(p.y, _invert(p.x)));
  final lambdaSq = _sqrMod(lambda);
  final x3 = _xor(_xor(lambdaSq, lambda), _one);
  final y3 = _xor(_xor(_sqrMod(p.x), _mulMod(lambda, x3)), x3);
  return _Point(x3, y3);
}

bool _eq(Uint32List a, Uint32List b) {
  for (var i = 0; i < _words; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

_Point _scalarMul(Uint32List scalar, _Point base) {
  var result = _Point.infinity;
  var addend = base;
  final bits = _highestBit(scalar);
  for (var bit = 0; bit <= bits; bit++) {
    final word = bit ~/ 32;
    final off = bit % 32;
    if ((scalar[word] >> off) & 1 != 0) {
      result = _pointAdd(result, addend);
    }
    addend = _pointDouble(addend);
  }
  return result;
}

/// Masks a raw 24-byte scalar to the private-key form this protocol uses:
/// clears bits 163 and above (byte 20's top 6 bits, bytes 21-23 zero).
Uint8List maskPrivateKey(Uint8List raw24) {
  final out = Uint8List.fromList(raw24);
  if (out.length != 24) throw ArgumentError('private key must be 24 bytes');
  out[20] &= 0x03;
  out[21] = 0;
  out[22] = 0;
  out[23] = 0;
  return out;
}

/// Derives the 48-byte public key for a given (already-masked) 24-byte
/// private key.
Uint8List publicKeyFor(Uint8List privateKey24) {
  final priv = _fromBytesLE(privateKey24);
  final base = _Point(_baseX, _baseY);
  final p = _scalarMul(priv, base);
  if (p.isInfinity) throw B163Error('private key produced the point at infinity');
  return Uint8List.fromList([..._toBytesLE(p.x), ..._toBytesLE(p.y)]);
}

/// Builds a keypair from 24 raw random bytes, masking them first.
B163Keypair keypairFrom(Uint8List raw24) {
  final priv = maskPrivateKey(raw24);
  return B163Keypair(priv, publicKeyFor(priv));
}

/// Generates a fresh keypair from a cryptographically secure random source.
/// Regenerates if the masked private key's bit length would fall below 81
/// bits (vanishingly unlikely; guards against a degenerate near-zero key).
B163Keypair generateKeypair([Random? random]) {
  final rng = random ?? Random.secure();
  while (true) {
    final raw = Uint8List.fromList([for (var i = 0; i < 24; i++) rng.nextInt(256)]);
    final priv = maskPrivateKey(raw);
    if (_highestBit(_fromBytesLE(priv)) < 80) continue; // < 81 significant bits
    try {
      return B163Keypair(priv, publicKeyFor(priv));
    } on B163Error {
      continue; // vanishingly unlikely: retry with a fresh private key
    }
  }
}

/// The shared secret: the X coordinate (24 bytes LE) of `privateKey * peerPublicKey`.
Uint8List sharedSecret(Uint8List privateKey24, Uint8List peerPublicKey48) {
  if (peerPublicKey48.length != 48) {
    throw B163Error('public key must be 48 bytes');
  }
  final peerX = _fromBytesLE(peerPublicKey48.sublist(0, 24));
  final peerY = _fromBytesLE(peerPublicKey48.sublist(24, 48));
  if (!_isOnCurve(peerX, peerY)) {
    throw B163Error('peer public key is not on the curve');
  }
  final priv = _fromBytesLE(privateKey24);
  final s = _scalarMul(priv, _Point(peerX, peerY));
  if (s.isInfinity) throw B163Error('shared secret is the point at infinity');
  return _toBytesLE(s.x);
}

bool _isOnCurve(Uint32List x, Uint32List y) {
  if (_isZero(x) && _isZero(y)) return false;
  // y^2 + xy = x^3 + x^2 + b
  final lhs = _xor(_sqrMod(y), _mulMod(x, y));
  final rhs = _xor(_xor(_mulMod(_sqrMod(x), x), _sqrMod(x)), _curveB);
  return _eq(lhs, rhs);
}
