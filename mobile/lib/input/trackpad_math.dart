// Pure math for the trackpad: pointer acceleration, scroll mapping and
// velocity estimation. No Flutter widgets here so it is trivially testable.

import 'dart:math' as math;

import '../motion/one_euro.dart';

/// Pointer acceleration curve: one continuous, smooth function of finger
/// speed (no thresholds, no gain steps):
///
///   x       = v / halfSpeed
///   gain(v) = base * (1 + k * x^p / (1 + x^p))
///   base    = pointerSpeed * (1 - precisionCut * a)
///   k       = hi / lo - 1,  hi = 1 + maxBoost * a,  lo = 1 - precisionCut * a
///
/// i.e. a precise gain at rest that rises along a sigmoid in `v^p` (p = 1.4)
/// toward the boosted gain. `a` is the acceleration setting (0 = Off,
/// ~0.6 = Natural, 1 = Strong); with `a == 0` the curve is flat (pure
/// linear tracking). `v` is finger speed in logical px/s.
abstract final class AccelerationCurve {
  /// Finger speed at which half of the boost applies.
  static const double halfSpeed = 650.0;

  /// Curve exponent.
  static const double exponent = 1.4;

  static const double precisionCut = 0.45;
  static const double maxBoost = 2.6;

  static double gain(
    double speed, {
    required double pointerSpeed,
    required double acceleration,
  }) {
    final v = speed.isFinite ? math.max(0.0, speed) : 0.0;
    final a = acceleration.clamp(0.0, 1.0);
    final lo = 1.0 - precisionCut * a;
    final hi = 1.0 + maxBoost * a;
    final xp = math.pow(v / halfSpeed, exponent).toDouble();
    final k = hi / lo - 1.0;
    return pointerSpeed * lo * (1.0 + k * xp / (1.0 + xp));
  }

  /// Gain at rest.
  static double minGain({
    required double pointerSpeed,
    required double acceleration,
  }) =>
      pointerSpeed * (1.0 - precisionCut * acceleration.clamp(0.0, 1.0));

  /// Asymptotic gain at very high speed.
  static double maxGain({
    required double pointerSpeed,
    required double acceleration,
  }) =>
      pointerSpeed * (1.0 + maxBoost * acceleration.clamp(0.0, 1.0));
}

/// Stateful accelerator: estimates finger speed with a 1€ filter (smooth at
/// low speed, low lag on flicks) and applies [AccelerationCurve] to the raw
/// delta. Feed it one coalesced delta per frame.
class PointerAccelerator {
  final OneEuroFilter _speedFilter =
      OneEuroFilter(minCutoff: 4.0, beta: 0.002, dCutoff: 1.0);
  int? _lastUs;
  double _t = 0;
  double _speed = 0;

  double get smoothedSpeed => _speed;

  void reset() {
    _speedFilter.reset();
    _lastUs = null;
    _t = 0;
    _speed = 0;
  }

  /// Returns the accelerated `(dx, dy)` for a raw finger delta observed at
  /// [timestampUs] (microseconds, any monotonic epoch).
  (double, double) apply(
    double dx,
    double dy,
    int timestampUs, {
    required double pointerSpeed,
    required double acceleration,
  }) {
    final last = _lastUs;
    _lastUs = timestampUs;
    var dt = last == null ? 1 / 120 : (timestampUs - last) / 1e6;
    // Events can share a timestamp (batched) or arrive after a pause.
    if (dt <= 0) dt = 1 / 240;
    dt = dt.clamp(1 / 1000, 0.1);
    _t += dt;
    final instant = math.sqrt(dx * dx + dy * dy) / dt;
    _speed = math.max(0.0, _speedFilter.filter(instant, _t));
    final g = AccelerationCurve.gain(
      _speed,
      pointerSpeed: pointerSpeed,
      acceleration: acceleration,
    );
    return (dx * g, dy * g);
  }
}

/// Maps a finger delta to a SCROLL payload per PROTOCOL.md:
/// `+dy` reveals content further down.
///
/// Natural scrolling: content follows the finger, so moving the finger up
/// (negative screen dy) reveals content further down (+dy).
abstract final class ScrollMapping {
  /// Base multiplier: one logical point of finger travel ≈ 1.6 px of scroll.
  static const double base = 1.6;

  static (double, double) map(
    double fingerDx,
    double fingerDy, {
    required double scrollSpeed,
    required bool natural,
  }) {
    final k = base * scrollSpeed * (natural ? -1.0 : 1.0);
    return (fingerDx * k, fingerDy * k);
  }
}

/// Velocity over a short sliding window (for scroll inertia).
class VelocityEstimator {
  VelocityEstimator({this.windowUs = 80000});

  final int windowUs;
  final List<_Sample> _samples = <_Sample>[];

  void reset() => _samples.clear();

  void add(double dx, double dy, int timestampUs) {
    _samples.add(_Sample(dx, dy, timestampUs));
    final cutoff = timestampUs - windowUs * 2;
    _samples.removeWhere((s) => s.t < cutoff);
  }

  /// Velocity in units/s, measured over the last [windowUs] ending at
  /// [nowUs]. Returns (0, 0) when the finger stopped before lifting.
  (double, double) velocity(int nowUs) {
    if (_samples.isEmpty) return (0.0, 0.0);
    final from = nowUs - windowUs;
    var sx = 0.0, sy = 0.0;
    int? first;
    var count = 0;
    for (final s in _samples) {
      if (s.t < from) continue;
      // The first sample's delta happened *before* its timestamp, so it is
      // the start marker, not part of the measured travel.
      if (first == null) {
        first = s.t;
      } else {
        sx += s.dx;
        sy += s.dy;
      }
      count++;
    }
    if (count < 2 || first == null) return (0.0, 0.0);
    // From the first included sample to now (at least one frame), so a
    // finger that stopped before lifting yields a low velocity.
    final span = math.max(nowUs - first, 8000) / 1e6;
    return (sx / span, sy / span);
  }
}

class _Sample {
  const _Sample(this.dx, this.dy, this.t);
  final double dx, dy;
  final int t;
}

/// Exponential-decay inertia (same law as Flutter's FrictionSimulation with
/// a per-second drag coefficient). Velocity v(t) = v0 * drag^t. The engine
/// evaluates a FrictionSimulation per frame; this stays as the pure model.
class Inertia {
  Inertia(this.vx, this.vy, {this.drag = 0.12});

  final double vx, vy;

  /// Fraction of velocity left after one second (iOS-like ≈ 0.135).
  final double drag;

  /// Position offset at time t (seconds).
  (double, double) offsetAt(double t) {
    final lnD = math.log(drag);
    final f = (math.pow(drag, t) - 1) / lnD;
    return (vx * f, vy * f);
  }

  double speedAt(double t) =>
      math.sqrt(vx * vx + vy * vy) * math.pow(drag, t).toDouble();

  bool isDone(double t, {double minSpeed = 25}) =>
      speedAt(t) < minSpeed || t > 3.0;
}
