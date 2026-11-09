// Damped spring with SwiftUI-style parameters, integrated exactly
// (closed-form per step), so it is frame-rate independent: stepping 1×16 ms
// or 4×4 ms gives the same result. Pure Dart, no Flutter imports.
//
//   response: period of the undamped oscillation in seconds (≈ how long it
//             takes to get there). 0.3–0.5 feels natural for UI.
//   damping:  damping ratio. 1 = critically damped (fastest, no overshoot),
//             < 1 bouncy, > 1 sluggish.
//
// Usage from a widget (e.g. a finger-following light), driven by a Ticker:
//
//   final light = Spring2D(response: 0.18, damping: 0.85);
//   light.target = finger;               // on pointer move
//   light.step(dtSeconds);               // every frame
//   paint at light.x, light.y;           // while light.isMoving
//
// `snapTo` jumps without animation (e.g. on pointer down).

import 'dart:math' as math;

class Spring {
  Spring({
    this.response = 0.35,
    this.damping = 1.0,
    double value = 0,
    this.restDistance = 0.01,
    this.restVelocity = 0.01,
  })  : _x = value,
        target = value;

  double response;
  double damping;
  double restDistance;
  double restVelocity;

  double target;
  double _x;
  double _v = 0;

  double get value => _x;
  double get velocity => _v;

  bool get isMoving =>
      (_x - target).abs() > restDistance || _v.abs() > restVelocity;

  void snapTo(double value) {
    _x = value;
    target = value;
    _v = 0;
  }

  /// Advances by [dt] seconds and returns the new value.
  double step(double dt) {
    if (!(dt > 0) || !dt.isFinite) return _x;
    // Big gaps (app paused) would be stable anyway; cap for sanity.
    if (dt > 0.25) dt = 0.25;
    final resp = response <= 1e-4 ? 1e-4 : response;
    final w0 = 2 * math.pi / resp; // natural angular frequency
    final z = damping < 0 ? 0.0 : damping;
    final x0 = _x - target;
    final v0 = _v;
    double x, v;
    if ((z - 1).abs() < 1e-6) {
      // Critically damped: x(t) = (x0 + (v0 + w0 x0) t) e^{-w0 t}
      final e = math.exp(-w0 * dt);
      final c = v0 + w0 * x0;
      x = (x0 + c * dt) * e;
      v = (c - w0 * (x0 + c * dt)) * e;
    } else if (z < 1) {
      final wd = w0 * math.sqrt(1 - z * z);
      final e = math.exp(-z * w0 * dt);
      final cos = math.cos(wd * dt), sin = math.sin(wd * dt);
      final b = (v0 + z * w0 * x0) / wd;
      x = e * (x0 * cos + b * sin);
      v = e * ((b * wd - z * w0 * x0) * cos - (x0 * wd + z * w0 * b) * sin);
    } else {
      // Overdamped: sum of two decaying exponentials.
      final s = w0 * math.sqrt(z * z - 1);
      final r1 = -z * w0 + s, r2 = -z * w0 - s;
      final c2 = (v0 - r1 * x0) / (r2 - r1);
      final c1 = x0 - c2;
      final e1 = math.exp(r1 * dt), e2 = math.exp(r2 * dt);
      x = c1 * e1 + c2 * e2;
      v = c1 * r1 * e1 + c2 * r2 * e2;
    }
    _x = target + x;
    _v = v;
    if (!isMoving) {
      _x = target;
      _v = 0;
    }
    return _x;
  }
}

/// Two independent springs sharing parameters (x / y positions).
class Spring2D {
  Spring2D({double response = 0.35, double damping = 1.0, double x = 0, double y = 0})
      : _sx = Spring(response: response, damping: damping, value: x),
        _sy = Spring(response: response, damping: damping, value: y);

  final Spring _sx, _sy;

  double get x => _sx.value;
  double get y => _sy.value;
  double get vx => _sx.velocity;
  double get vy => _sy.velocity;
  bool get isMoving => _sx.isMoving || _sy.isMoving;

  set response(double r) => _sx.response = _sy.response = r;
  set damping(double d) => _sx.damping = _sy.damping = d;

  void setTarget(double x, double y) {
    _sx.target = x;
    _sy.target = y;
  }

  void snapTo(double x, double y) {
    _sx.snapTo(x);
    _sy.snapTo(y);
  }

  void step(double dt) {
    _sx.step(dt);
    _sy.step(dt);
  }
}
