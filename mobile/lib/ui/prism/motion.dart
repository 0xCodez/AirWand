import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

const double _tau = math.pi * 2;

/// Damped harmonic oscillator, unit mass (prototype `Spring`).
/// [response] is the period of the undamped spring in seconds and [damping]
/// the damping ratio. Integrated semi-implicitly with ~240 Hz substeps, so it
/// is dt-correct at any frame rate.
class SpringValue {
  SpringValue(
    double initial, {
    double response = 0.42,
    double damping = 0.84,
    this.epsilon = 0.001,
  })  : value = initial,
        target = initial {
    configure(response: response, damping: damping);
  }

  double value;
  double velocity = 0;
  double target;
  final double epsilon;
  double _k = 0;
  double _c = 0;

  void configure({double response = 0.42, double damping = 0.84}) {
    final r = response <= 0.001 ? 0.001 : response;
    _k = math.pow(_tau / r, 2).toDouble();
    _c = 4 * math.pi * damping / r;
  }

  bool get settled =>
      (value - target).abs() < epsilon && velocity.abs() < epsilon * 8;

  void step(double dtSeconds) {
    if (dtSeconds <= 0) return;
    if (settled) {
      value = target;
      velocity = 0;
      return;
    }
    final dt = dtSeconds > 0.1 ? 0.1 : dtSeconds;
    final n = math.max(1, (dt * 240).ceil());
    final h = dt / n;
    for (var i = 0; i < n; i++) {
      final a = -_k * (value - target) - _c * velocity;
      velocity += a * h;
      value += velocity * h;
    }
  }

  /// Jump to [v] with no motion.
  void snap(double v) {
    value = v;
    target = v;
    velocity = 0;
  }
}

/// 2-D spring over [Offset] (prototype `Spring2`).
class SpringOffset {
  SpringOffset(
    Offset initial, {
    double response = 0.42,
    double damping = 0.84,
    this.epsilon = 0.05,
  })  : value = initial,
        target = initial {
    configure(response: response, damping: damping);
  }

  Offset value;
  Offset velocity = Offset.zero;
  Offset target;
  final double epsilon;
  double _k = 0;
  double _c = 0;

  void configure({double response = 0.42, double damping = 0.84}) {
    final r = response <= 0.001 ? 0.001 : response;
    _k = math.pow(_tau / r, 2).toDouble();
    _c = 4 * math.pi * damping / r;
  }

  bool get settled =>
      (value - target).distance < epsilon && velocity.distance < epsilon * 8;

  void step(double dtSeconds) {
    if (dtSeconds <= 0) return;
    if (settled) {
      value = target;
      velocity = Offset.zero;
      return;
    }
    final dt = dtSeconds > 0.1 ? 0.1 : dtSeconds;
    final n = math.max(1, (dt * 240).ceil());
    final h = dt / n;
    var x = value.dx, y = value.dy, vx = velocity.dx, vy = velocity.dy;
    final tx = target.dx, ty = target.dy;
    for (var i = 0; i < n; i++) {
      vx += (-_k * (x - tx) - _c * vx) * h;
      vy += (-_k * (y - ty) - _c * vy) * h;
      x += vx * h;
      y += vy * h;
    }
    value = Offset(x, y);
    velocity = Offset(vx, vy);
  }

  void snap(Offset v) {
    value = v;
    target = v;
    velocity = Offset.zero;
  }
}

/// Frame loop for spring-driven widgets.
///
/// ```dart
/// class _S extends State<W> with TickerProviderStateMixin, SpringTicker<W> {
///   @override bool get animating => !spring.settled;
///   @override void onFrame(double dt) { spring.step(dt); setState(() {}); }
/// }
/// ```
/// Call [wake] whenever a target changes; the ticker stops itself once
/// [animating] is false.
mixin SpringTicker<T extends StatefulWidget>
    on State<T>, TickerProviderStateMixin<T> {
  Ticker? _springTicker;
  Duration _last = Duration.zero;

  bool get animating;
  void onFrame(double dt);

  void wake() {
    if (!mounted) return;
    final t = _springTicker ??= createTicker(_tick);
    if (!t.isActive) {
      _last = Duration.zero;
      t.start();
    }
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.1) dt = 1 / 60;
    onFrame(dt);
    if (!animating) _springTicker?.stop();
  }

  @override
  void dispose() {
    _springTicker?.dispose();
    _springTicker = null;
    super.dispose();
  }
}
