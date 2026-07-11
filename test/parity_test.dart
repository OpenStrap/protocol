// Parity test: decode_parity_cases.json (2934 cases) — the 1:1 oracle.
// Each case: { "kind": "r24"|"record"|"rr"|"accel", "hex": "...", "out": {...}|null }
// Route per kind; deep-compare against `out`. Ints exact, doubles within 1e-4.

import 'dart:convert';
import 'dart:io';

import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

const double _eps = 1e-4;

/// Deep comparison. Returns null if equal, else a description of the mismatch.
String? _diff(dynamic actual, dynamic expected, String path) {
  if (expected == null) {
    return actual == null ? null : 'at $path: expected null, got $actual';
  }
  if (actual == null) return 'at $path: expected $expected, got null';

  if (expected is num && actual is num) {
    if (expected is int && actual is int) {
      return expected == actual ? null : 'at $path: int $actual != $expected';
    }
    // float comparison
    if ((actual.toDouble() - expected.toDouble()).abs() <= _eps) return null;
    return 'at $path: num $actual != $expected (>$_eps)';
  }
  if (expected is bool) {
    return actual == expected ? null : 'at $path: bool $actual != $expected';
  }
  if (expected is String) {
    return actual == expected ? null : 'at $path: str "$actual" != "$expected"';
  }
  if (expected is List) {
    if (actual is! List) return 'at $path: expected List, got ${actual.runtimeType}';
    if (actual.length != expected.length) {
      return 'at $path: list len ${actual.length} != ${expected.length}';
    }
    for (int i = 0; i < expected.length; i++) {
      final d = _diff(actual[i], expected[i], '$path[$i]');
      if (d != null) return d;
    }
    return null;
  }
  if (expected is Map) {
    if (actual is! Map) return 'at $path: expected Map, got ${actual.runtimeType}';
    for (final k in expected.keys) {
      final d = _diff(actual[k], expected[k], '$path.$k');
      if (d != null) return d;
    }
    // Ensure actual carries no extra keys that expected lacks (1:1 shape).
    // xs/ys/zs got added to ImuFrame.toMap() for raw-axis diagnostics after
    // these fixtures were generated from the TS oracle, so they're not in
    // `expected` here - allow just those, still fail on anything else new.
    const allowedExtras = {'xs', 'ys', 'zs'};
    for (final k in actual.keys) {
      if (!expected.containsKey(k) && !allowedExtras.contains(k)) {
        return 'at $path.$k: unexpected extra key (value ${actual[k]})';
      }
    }
    return null;
  }
  return 'at $path: unhandled types ${actual.runtimeType}/${expected.runtimeType}';
}

/// Produce the decoded `out`-shaped map (or null) for a parity case.
dynamic _decode(String kind, String hex) {
  switch (kind) {
    case 'r24':
      final r = parseR24(hexToBytes(hex));
      return r?.toMap();
    case 'record':
      final s = decodeRecord(hex);
      return s?.toMap();
    case 'rr':
      final r = realtimeRr(hex);
      return r?.toMap();
    case 'accel':
      final a = frameAccel(hex);
      return a?.toMap();
    default:
      throw StateError('unknown kind: $kind');
  }
}

void main() {
  final file = File('decode_parity_cases.json');
  final cases = json.decode(file.readAsStringSync()) as List;

  test('decode_parity_cases.json — all ${cases.length} cases match oracle', () {
    expect(cases.length, 2934, reason: 'expected 2934 parity cases');
    int matched = 0;
    final failures = <String>[];
    for (int i = 0; i < cases.length; i++) {
      final c = cases[i] as Map<String, dynamic>;
      final kind = c['kind'] as String;
      final hex = c['hex'] as String;
      final expected = c['out'];
      final actual = _decode(kind, hex);
      final d = _diff(actual, expected, 'case[$i]($kind)');
      if (d == null) {
        matched++;
      } else if (failures.length < 20) {
        failures.add(d);
      }
    }
    expect(matched, cases.length,
        reason: 'matched $matched/${cases.length}; first failures:\n'
            '${failures.join('\n')}');
  });
}
