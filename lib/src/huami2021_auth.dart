// The Huami2021/ZeppOS auth handshake, endpoint 0x0082: a pure state machine
// over five framed steps, using a pre-shared 16-byte auth key and B-163 ECDH
// to derive a fresh session key each time.
//
//   1  phone  ->  04 02 00 02 | ourPublicKey[48]            (52 bytes)
//   2  device ->  10 04 status | remoteRandom[16] | devicePublicKey[48]
//   3  --     shared = ECDH(ourPrivate, devicePublicKey)
//              sequence   = u32LE(shared[0:4])
//              sessionKey[i] = shared[i+8] XOR authKey[i], i = 0..15
//   4  phone  ->  05 | AES_ECB(authKey, remoteRandom) | AES_ECB(sessionKey, remoteRandom)
//   5  device ->  10 05 status                               (0x01 success, 0x25 wrong key)
//
// The caller frames step 1's and step 4's payloads on endpoint
// [kHuami2021AuthEndpoint] (unencrypted) with a chunk encoder, and feeds
// reassembled endpoint-0x0082 payloads to [Huami2021Auth.onPayload]. Secrets
// (auth key, session key) never appear in a failure's fields.

import 'dart:typed_data';

import 'b163.dart';
import 'huami2021_chunks.dart' show AesEcb;

/// The auth endpoint every step above is framed on.
const int kHuami2021AuthEndpoint = 0x0082;

const int _cmdPublicKey = 0x04;
const int _cmdSessionKey = 0x05;
const int _responsePrefix = 0x10;
const int _statusOk = 0x01;
const int _statusWrongKey = 0x25;

enum _State { idle, sentPublicKey, sentProof, done }

/// Why the device refused, or why a reply couldn't be used.
sealed class Huami2021AuthFailure {
  const Huami2021AuthFailure();
}

/// Status `0x25` on step 5: the auth key does not match this device's pairing.
class WrongAuthKey extends Huami2021AuthFailure {
  const WrongAuthKey();
}

/// Any other non-success status, at the step it arrived on.
class AuthRejected extends Huami2021AuthFailure {
  const AuthRejected(this.step, this.status);
  final int step;
  final int status;
}

/// A reply that doesn't have the shape this step requires.
class AuthMalformed extends Huami2021AuthFailure {
  const AuthMalformed(this.reason);
  final String reason;
}

/// What [Huami2021Auth.onPayload] reports back to the caller.
sealed class Huami2021AuthEvent {
  const Huami2021AuthEvent();
}

/// Not a reply this handshake is waiting for right now.
class Huami2021AuthIgnored extends Huami2021AuthEvent {
  const Huami2021AuthIgnored();
}

/// Step 4: frame and send this payload on [kHuami2021AuthEndpoint].
class Huami2021AuthSendProof extends Huami2021AuthEvent {
  const Huami2021AuthSendProof(this.payload);
  final Uint8List payload;
}

/// Step 5 succeeded. [sessionKey] and [sequence] seed the chunk transport's
/// encryption from here on.
class Huami2021Authenticated extends Huami2021AuthEvent {
  const Huami2021Authenticated(this.sessionKey, this.sequence);
  final Uint8List sessionKey;
  final int sequence;

  @override
  String toString() => 'Huami2021Authenticated(sequence: <redacted>)';
}

class Huami2021AuthFailed extends Huami2021AuthEvent {
  const Huami2021AuthFailed(this.failure);
  final Huami2021AuthFailure failure;
}

/// Drives the five-step handshake above. One instance per connection
/// attempt; [start] may be called only once.
class Huami2021Auth {
  Huami2021Auth(Uint8List authKey, {required AesEcb aesEcb, B163Keypair? keypair})
      : _authKey = Uint8List.fromList(authKey),
        _aes = aesEcb,
        _keypair = keypair ?? generateKeypair() {
    if (_authKey.length != 16) {
      throw ArgumentError('auth key must be 16 bytes');
    }
  }

  final Uint8List _authKey;
  final AesEcb _aes;
  final B163Keypair _keypair;
  _State _state = _State.idle;
  Uint8List? _sessionKey;
  int _sequence = 0;

  /// Step 1's payload: `04 02 00 02` followed by our 48-byte public key.
  Uint8List start() {
    if (_state != _State.idle) {
      throw StateError('handshake already started');
    }
    _state = _State.sentPublicKey;
    return Uint8List.fromList(
        [_cmdPublicKey, 0x02, 0x00, 0x02, ..._keypair.publicKey]);
  }

  /// Feeds one reassembled payload from endpoint 0x0082. Steps 2 and 5 are
  /// the only replies ever expected; anything else is [Huami2021AuthIgnored].
  Huami2021AuthEvent onPayload(Uint8List payload) {
    if (payload.length < 3 || payload[0] != _responsePrefix) {
      return const Huami2021AuthIgnored();
    }
    final cmd = payload[1];
    final status = payload[2];
    if (cmd == _cmdPublicKey && _state == _State.sentPublicKey) {
      return _onPublicKeyReply(status, payload);
    }
    if (cmd == _cmdSessionKey && _state == _State.sentProof) {
      return _onSessionReply(status);
    }
    return const Huami2021AuthIgnored();
  }

  Huami2021AuthEvent _onPublicKeyReply(int status, Uint8List payload) {
    if (status != _statusOk) {
      return _fail(AuthRejected(2, status));
    }
    if (payload.length < 3 + 16 + 48) {
      return _fail(AuthMalformed(
          'step 2 reply is ${payload.length} bytes, need ${3 + 16 + 48}'));
    }
    final remoteRandom = payload.sublist(3, 19);
    final devicePublicKey = payload.sublist(19, 19 + 48);
    final Uint8List shared;
    try {
      shared = sharedSecret(_keypair.privateKey, devicePublicKey);
    } on B163Error catch (e) {
      return _fail(AuthMalformed(e.message?.toString() ?? 'bad device public key'));
    }
    _sequence = ByteData.sublistView(shared, 0, 4).getUint32(0, Endian.little);
    final session = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      session[i] = shared[i + 8] ^ _authKey[i];
    }
    _sessionKey = session;
    _state = _State.sentProof;
    final proof = Uint8List.fromList([
      _cmdSessionKey,
      ..._aes(_authKey, remoteRandom),
      ..._aes(session, remoteRandom),
    ]);
    return Huami2021AuthSendProof(proof);
  }

  Huami2021AuthEvent _onSessionReply(int status) {
    if (status == _statusOk) {
      _state = _State.done;
      return Huami2021Authenticated(_sessionKey!, _sequence);
    }
    if (status == _statusWrongKey) {
      return _fail(const WrongAuthKey());
    }
    return _fail(AuthRejected(5, status));
  }

  Huami2021AuthEvent _fail(Huami2021AuthFailure failure) {
    _state = _State.done;
    return Huami2021AuthFailed(failure);
  }

  @override
  String toString() => 'Huami2021Auth(state: $_state)';
}
