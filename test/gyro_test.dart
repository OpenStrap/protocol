import 'dart:io';
import 'dart:math';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:test/test.dart';

// R10 gyro/accel decode, verified against a real 1920-byte live R10 record
// captured from a worn band (HR=87 bpm, ts=31624534 device-clock).
void main() {
  final hex = File('test/r10_fixture.hex').readAsStringSync().trim();

  test('decodeR10Imu decodes a real R10 record', () {
    final imu = decodeR10Imu(hex);
    expect(imu, isNotNull);
    final m = imu!;

    // header timestamp (device clock)
    expect(m.ts, 31624534);

    // 100 samples per axis
    for (final a in [m.accelX, m.accelY, m.accelZ, m.gyroX, m.gyroY, m.gyroZ]) {
      expect(a.length, 100);
    }

    // first-sample values pinned to the Python reference decode
    expect(m.accelX[0], closeTo(-0.7847, 1e-3));
    expect(m.gyroX[0], closeTo(4.6387, 1e-3));
    expect(m.gyroY[0], closeTo(1.3428, 1e-3));
    expect(m.gyroZ[0], closeTo(0.2441, 1e-3));

    // physical sanity: accel sits at ~1 g (gravity); gyro within ±2000 dps and
    // motion-scale (not clipped, not constant) for a near-still wrist.
    double mag(List<double> x, List<double> y, List<double> z, int i) =>
        sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]);
    final accelMags = [for (var i = 0; i < 100; i++) mag(m.accelX, m.accelY, m.accelZ, i)];
    final meanAccel = accelMags.reduce((a, b) => a + b) / 100;
    expect(meanAccel, closeTo(1.0, 0.2));

    final allGyro = [...m.gyroX, ...m.gyroY, ...m.gyroZ];
    expect(allGyro.every((v) => v.abs() <= 2000), isTrue);
    expect(allGyro.any((v) => v.abs() > 1.0), isTrue); // not flat/constant
  });

  test('decodeR10Imu rejects non-R10 input', () {
    expect(decodeR10Imu('2f1805f1'), isNull); // type-24 fragment
    expect(decodeR10Imu('2b0a'), isNull); // too short
  });
}
