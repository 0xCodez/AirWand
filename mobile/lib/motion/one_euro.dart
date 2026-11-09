// The 1€ filter (Casiez, Roussel, Vogel — CHI 2012): an adaptive low-pass
// filter that removes jitter at low speed and keeps lag low at high speed.
// Pure Dart (no Flutter imports) so it is trivially unit-testable.

import 'dart:math' as math;

class OneEuroFilter {
  OneEuroFilter({this.minCutoff = 1.0, this.beta = 0.007, this.dCutoff = 1.0});

  /// Minimum cutoff frequency in Hz (lower = smoother at rest).
  final double minCutoff;

  /// Speed coefficient: how fast the cutoff rises with |dx/dt|.
  final double beta;

  /// Cutoff for the derivative estimate, in Hz.
  final double dCutoff;

  double? _x;
  double _dx = 0;
  double? _t;

  bool get hasValue => _x != null;
  double get value => _x ?? 0;

  /// Filtered derivative (units per second).
  double get derivative => _dx;

  void reset() {
    _x = null;
    _dx = 0;
    _t = null;
  }

  static double _alpha(double cutoff, double dt) {
    final tau = 1.0 / (2 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }

  /// Filters sample [x] taken at time [t] (seconds, monotonic).
  double filter(double x, double t) {
    final px = _x, pt = _t;
    if (px == null || pt == null || !x.isFinite) {
      if (!x.isFinite) return value;
      _x = x;
      _dx = 0;
      _t = t;
      return x;
    }
    var dt = t - pt;
    if (!(dt > 1e-6)) dt = 1 / 120; // duplicate / out-of-order timestamps
    final rawDx = (x - px) / dt;
    _dx += _alpha(dCutoff, dt) * (rawDx - _dx);
    final cutoff = minCutoff + beta * _dx.abs();
    final xHat = px + _alpha(cutoff, dt) * (x - px);
    _x = xHat;
    _t = pt + dt;
    return xHat;
  }
}
