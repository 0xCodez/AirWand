// Air-pointer orientation from the gyroscope, fused with the accelerometer.
//
// Yaw   = rotation about the gravity ("up") vector, integrated from the gyro.
//         Projecting the rotation rate onto gravity makes it independent of
//         how the phone is held (flat like a remote or upright).
// Pitch = rotation about the device x axis, integrated from the gyro and
//         pulled toward the accelerometer tilt with a complementary filter
//         (removes long-term drift; yaw has no absolute reference and relies
//         on "Center").
//
// Output angles are radians relative to the calibrated center:
// +yaw = right, +pitch = up (PROTOCOL.md AIM). They are clamped to the host
// ranges; pushing past an edge drags the center along ("clutching"), so the
// pointer starts moving back the moment you turn back.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

class AirTracker extends ChangeNotifier {
  AirTracker();

  /// Host maps ±yawRange to the full desktop width.
  static const double yawRange = 0.35;

  /// Host maps ±pitchRange to the full desktop height.
  static const double pitchRange = 0.20;

  /// Complementary filter weight of the integrated gyro.
  static const double gyroWeight = 0.98;

  /// Rates below this (rad/s) are treated as hand tremor / bias.
  static const double deadBand = 0.004;

  static const Duration _sampling = Duration(milliseconds: 10);

  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<AccelerometerEvent>? _accSub;

  // Low-passed gravity ("up" vector) in device coordinates, m/s².
  double _gx = 0, _gy = 0, _gz = 9.81;
  bool _haveGravity = false;

  double _yaw = 0; // relative, clamped
  double _pitchAbs = 0; // absolute fused pitch
  double _pitchCenter = 0;
  bool _pitchInit = false;

  final Stopwatch _clock = Stopwatch();
  int? _lastUs;
  bool _available = true;
  String? _error;

  /// Called on every gyro sample with the current relative aim.
  void Function(double yaw, double pitch)? onAim;

  double get yaw => _yaw;
  double get pitch =>
      _wrap(_pitchAbs - _pitchCenter).clamp(-pitchRange, pitchRange);
  bool get available => _available;
  String? get error => _error;
  bool get running => _gyroSub != null;

  /// Normalized position on the target screen: (-1..1, -1..1), +y = up.
  (double, double) get normalized => (yaw / yawRange, pitch / pitchRange);

  void start() {
    if (_gyroSub != null) return;
    _clock
      ..reset()
      ..start();
    _lastUs = null;
    try {
      _accSub = accelerometerEventStream(samplingPeriod: _sampling).listen(
        _onAccel,
        onError: (Object e) => _fail('Accelerometer unavailable'),
        cancelOnError: true,
      );
      _gyroSub = gyroscopeEventStream(samplingPeriod: _sampling).listen(
        _onGyro,
        onError: (Object e) => _fail('This phone has no gyroscope'),
        cancelOnError: true,
      );
    } catch (e) {
      _fail('Motion sensors unavailable');
    }
  }

  void stop() {
    _gyroSub?.cancel();
    _gyroSub = null;
    _accSub?.cancel();
    _accSub = null;
    _clock.stop();
  }

  /// Zero yaw and pitch at the current orientation.
  void center() {
    _yaw = 0;
    _pitchCenter = _pitchAbs;
    notifyListeners();
  }

  void _fail(String message) {
    _available = false;
    _error = message;
    stop();
    notifyListeners();
  }

  void _onAccel(AccelerometerEvent e) {
    if (!_haveGravity) {
      _gx = e.x;
      _gy = e.y;
      _gz = e.z;
      _haveGravity = true;
    } else {
      // ~0.1 → roughly 100 ms time constant at 100 Hz.
      const a = 0.1;
      _gx += (e.x - _gx) * a;
      _gy += (e.y - _gy) * a;
      _gz += (e.z - _gz) * a;
    }
    if (!_pitchInit) {
      _pitchAbs = _accelPitch();
      _pitchCenter = _pitchAbs;
      _pitchInit = true;
    }
  }

  /// Elevation of the device y axis about the x axis, from gravity.
  double _accelPitch() => math.atan2(_gy, _gz);

  void _onGyro(GyroscopeEvent e) {
    final now = _clock.elapsedMicroseconds;
    final last = _lastUs;
    _lastUs = now;
    if (last == null) return;
    final dt = ((now - last) / 1e6).clamp(0.0, 0.05);
    if (dt == 0) return;

    // Unit "up" vector.
    final gn = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    final ux = gn > 0.1 ? _gx / gn : 0.0;
    final uy = gn > 0.1 ? _gy / gn : 0.0;
    final uz = gn > 0.1 ? _gz / gn : 1.0;

    // Turning right = clockwise seen from above = negative rotation about up.
    var yawRate = -(e.x * ux + e.y * uy + e.z * uz);
    var pitchRate = e.x;
    if (yawRate.abs() < deadBand) yawRate = 0;
    if (pitchRate.abs() < deadBand) pitchRate = 0;

    _yaw = (_yaw + yawRate * dt).clamp(-yawRange, yawRange);

    final gyroPitch = _pitchAbs + pitchRate * dt;
    if (_haveGravity) {
      final accPitch = _accelPitch();
      _pitchAbs =
          _wrap(gyroPitch + (1 - gyroWeight) * _wrap(accPitch - gyroPitch));
    } else {
      _pitchAbs = _wrap(gyroPitch);
    }
    // Clutch: keep relative pitch inside the mapped range.
    final rel = _wrap(_pitchAbs - _pitchCenter);
    if (rel > pitchRange) {
      _pitchCenter = _pitchAbs - pitchRange;
    } else if (rel < -pitchRange) {
      _pitchCenter = _pitchAbs + pitchRange;
    }

    onAim?.call(_yaw, pitch);
    notifyListeners();
  }

  static double _wrap(double a) {
    var x = a;
    while (x > math.pi) {
      x -= 2 * math.pi;
    }
    while (x < -math.pi) {
      x += 2 * math.pi;
    }
    return x;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
