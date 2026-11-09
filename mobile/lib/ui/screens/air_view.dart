import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../input/air_tracker.dart';
import '../../net/protocol.dart';
import '../../state/scope.dart';
import '../prism/prism.dart';
import 'mode_kit.dart';

/// Air pointer: an aim map on top, a chrome lens you hold to aim, and
/// Left / Center / Right capsules. The gyro drives the pointer while the
/// lens is held; on devices without a gyro, dragging on the lens aims.
class AirView extends StatefulWidget {
  const AirView({super.key, this.topInset = 0, this.bottomInset = 0});

  final double topInset;
  final double bottomInset;

  @override
  State<AirView> createState() => _AirViewState();
}

class _AirViewState extends State<AirView> with SingleTickerProviderStateMixin {
  final AirTracker _air = AirTracker();
  AirWandServices? _s;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _t = 0;

  bool _holding = false;
  String _state = 'Gyro · AIM 0x09';

  // Finger-driven aim (fallback when there is no gyro).
  double _fYaw = 0, _fPitch = 0, _sYaw = 0, _sPitch = 0;
  Offset _start = Offset.zero;
  bool _centering = false;

  // Springs (prototype values).
  final SpringOffset _dot = SpringOffset(Offset.zero, response: 0.2, damping: 0.86);
  final SpringOffset _light = SpringOffset(Offset.zero, response: 0.18, damping: 0.8);
  final SpringValue _la = SpringValue(0, response: 0.35, damping: 1);
  final SpringValue _rx = SpringValue(0, response: 0.4, damping: 0.7);
  final SpringValue _ry = SpringValue(0, response: 0.4, damping: 0.7);
  final SpringValue _scale = SpringValue(1, response: 0.35, damping: 0.65);
  final List<_Trail> _trail = <_Trail>[];
  Size _aimSize = Size.zero;
  double _lensSize = 0;
  bool _placed = false;

  bool get _gyro => _air.available && _air.running;

  @override
  void initState() {
    super.initState();
    _air.onAim = (yaw, pitch) {
      if (_holding) _s?.control.aim(yaw, pitch);
    };
    _air.addListener(_onTracker);
    _air.start();
    _ticker.start();
  }

  void _onTracker() {
    if (!_air.available && mounted) {
      setState(() => _state = 'No gyro · drag to aim');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _s ??= AirWandScope.of(context);
  }

  (double, double) get _aim {
    if (_gyro) return (_air.yaw, _air.pitch);
    return (_fYaw, _fPitch);
  }

  void _tick(Duration e) {
    final dt = (_last == Duration.zero
            ? 1 / 60
            : (e - _last).inMicroseconds / 1e6)
        .clamp(0.0, 0.05);
    _last = e;
    _t += dt;
    if (_centering) {
      final k = math.exp(-dt * 14);
      _fYaw *= k;
      _fPitch *= k;
      if (_fYaw.abs() + _fPitch.abs() < 0.0005) {
        _fYaw = _fPitch = 0;
        _centering = false;
      }
    }
    if (_aimSize != Size.zero) {
      final w = _aimSize.width, h = _aimSize.height;
      final (yaw0, pitch0) = _aim;
      // Hand tremor while holding, like the prototype.
      final ty = _holding ? math.sin(_t * 7) * 0.0035 + math.sin(_t * 16.4) * 0.0014 : 0.0;
      final tp = _holding ? math.cos(_t * 5.8) * 0.0028 + math.sin(_t * 18.9) * 0.001 : 0.0;
      final yaw = (yaw0 + (_gyro ? 0.0 : ty)).clamp(-AirTracker.yawRange, AirTracker.yawRange);
      final pitch = (pitch0 + (_gyro ? 0.0 : tp)).clamp(-AirTracker.pitchRange, AirTracker.pitchRange);
      final target = Offset(
        w / 2 + (yaw / AirTracker.yawRange) * (w / 2 - 14),
        h / 2 - (pitch / AirTracker.pitchRange) * (h / 2 - 14),
      );
      if (!_placed) {
        _dot.snap(target);
        _placed = true;
      }
      _dot.target = target;
      _dot.step(dt);
      if (_holding) _trail.add(_Trail(_dot.value));
      for (final q in _trail) {
        q.age += dt;
      }
      _trail.removeWhere((q) => q.age >= 0.5);
    }
    for (final s in <SpringValue>[_la, _rx, _ry, _scale]) {
      s.step(dt);
    }
    _light.step(dt);
    setState(() {});
  }

  void _down(Offset local) {
    _holding = true;
    _centering = false;
    _start = local;
    _sYaw = _fYaw;
    _sPitch = _fPitch;
    _light.snap(local);
    _light.target = local;
    _la.target = 1;
    _scale.target = 0.965;
    _state = 'AIM 0x09 · streaming';
    _s?.haptics.light();
    if (_gyro) {
      _s?.control.aim(_air.yaw, _air.pitch);
    } else {
      _s?.control.aim(_fYaw, _fPitch);
    }
  }

  void _move(Offset local) {
    if (!_holding) return;
    final size = _lensSize <= 0 ? 200.0 : _lensSize;
    final d = local - _start;
    if (!_gyro) {
      _fYaw = (_sYaw + d.dx / (size * 1.4) * 0.35)
          .clamp(-AirTracker.yawRange, AirTracker.yawRange);
      _fPitch = (_sPitch - d.dy / (size * 1.4) * 0.32)
          .clamp(-AirTracker.pitchRange, AirTracker.pitchRange);
      _s?.control.aim(_fYaw, _fPitch);
    }
    _light.target = local;
    _ry.target = (d.dx * 0.08).clamp(-14.0, 14.0);
    _rx.target = (-d.dy * 0.08).clamp(-14.0, 14.0);
  }

  void _up() {
    if (!_holding) return;
    _holding = false;
    _la.target = 0;
    _scale.target = 1;
    _rx.target = 0;
    _ry.target = 0;
    _state = 'Released';
    _s?.haptics.selection();
  }

  void _center() {
    _air.center();
    _centering = true;
    _state = 'Centered';
    _s?.haptics.medium();
    if (_holding) _s?.control.aim(0, 0);
  }

  void _button(int b, bool down) {
    _s?.control.button(b, down);
    if (down) {
      _s?.haptics.selection();
      _la.velocity += 6;
      setState(() => _state = b == MouseButton.right ? 'Click right' : 'Click left');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _air.onAim = null;
    _air.removeListener(_onTracker);
    _air.stop();
    _air.dispose();
    super.dispose();
  }

  String _fmt(String k, double v) =>
      '$k ${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(3)}';

  @override
  Widget build(BuildContext context) {
    final s = AirWandScope.of(context);
    final spectrum = activeSpectrum(s);
    final host = activeHost(s);
    final (yaw, pitch) = _aim;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, widget.topInset + 2, 14, widget.bottomInset),
      child: Column(children: <Widget>[
        SizedBox(
          height: 150,
          child: PrismGlass(
            radius: 22,
            spectrum: spectrum,
            child: LayoutBuilder(builder: (context, c) {
              _aimSize = Size(c.maxWidth, c.maxHeight);
              return Stack(children: <Widget>[
                Positioned.fill(
                  child: CustomPaint(
                    painter: _AimPainter(
                      dot: _dot.value,
                      trail: _trail,
                      holding: _holding,
                      spectrum: spectrum,
                    ),
                  ),
                ),
                const Positioned(top: 12, left: 14, child: Cap('Aim map')),
                Positioned(
                  top: 12,
                  right: 14,
                  child: Cap(host?.name ?? 'No computer'),
                ),
                Positioned(bottom: 11, left: 14, child: Cap(_fmt('yaw', yaw))),
                Positioned(bottom: 11, right: 14, child: Cap(_fmt('pitch', pitch))),
              ]);
            }),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final size = math.max(
                60.0,
                math.min(
                    math.min(232.0, MediaQuery.sizeOf(context).width * 0.62),
                    c.maxHeight - 12));
            _lensSize = size;
            if (_light.value == Offset.zero) {
              _light.snap(Offset(size / 2, size * 0.8));
            }
            final m = Matrix4.identity()
              ..setEntry(3, 2, 1 / 700)
              ..rotateX(_rx.value * math.pi / 180)
              ..rotateY(_ry.value * math.pi / 180)
              ..multiply(Matrix4.diagonal3Values(_scale.value, _scale.value, 1));
            return Center(
              child: Transform(
                alignment: Alignment.center,
                transform: m,
                child: SizedBox.square(
                  dimension: size,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _down(e.localPosition),
                    onPointerMove: (e) => _move(e.localPosition),
                    onPointerUp: (_) => _up(),
                    onPointerCancel: (_) => _up(),
                    child: ChromeRim(
                      child: Stack(fit: StackFit.expand, children: <Widget>[
                        const ColoredBox(color: Color(0xFF050507)),
                        CustomPaint(
                          painter: _LensPainter(
                            t: _t,
                            light: _light.value,
                            velocity: _light.velocity,
                            la: _la.value.clamp(0.0, 1.6),
                            spectrum: spectrum,
                          ),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: Alignment(0, -1),
                              radius: 1.1,
                              colors: <Color>[Color(0x1FFFFFFF), Color(0x00FFFFFF)],
                              stops: <double>[0, 0.55],
                            ),
                          ),
                        ),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Text(_holding ? 'Aiming' : 'Hold to aim',
                                style: uiText(19, weight: FontWeight.w600, tracking: -0.02)),
                            const SizedBox(height: 6),
                            Cap(_state),
                          ],
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(children: <Widget>[
            Expanded(
              child: _Capsule(
                label: 'Left',
                onDown: (d) => _button(MouseButton.left, d),
              ),
            ),
            const SizedBox(width: 10),
            _Capsule(
              label: 'Center',
              icon: Icons.center_focus_strong_rounded,
              onTap: _center,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Capsule(
                label: 'Right',
                onDown: (d) => _button(MouseButton.right, d),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Trail {
  _Trail(this.p);
  final Offset p;
  double age = 0;
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.label, this.icon, this.onTap, this.onDown});

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onDown;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      onDown: onDown,
      child: SizedBox(
        height: 46,
        child: PrismGlass(
          radius: 999,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 16, color: P.text),
                const SizedBox(width: 8),
              ],
              Text(label, style: uiText(14, weight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AimPainter extends CustomPainter {
  _AimPainter({
    required this.dot,
    required this.trail,
    required this.holding,
    required this.spectrum,
  });

  final Offset dot;
  final List<_Trail> trail;
  final bool holding;
  final List<Color> spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final grid = Paint();
    for (var i = 1; i < 12; i++) {
      for (var j = 1; j < 6; j++) {
        final g = Offset(w * i / 12, h * j / 6);
        final near = math.exp(-(g - dot).distance / 60);
        grid.color = withA(Colors.white, 0.12 + 0.5 * near);
        canvas.drawRect(Rect.fromCenter(center: g, width: 1.2, height: 1.2), grid);
      }
    }
    final dash = Paint()
      ..color = withA(Colors.white, 0.1)
      ..strokeWidth = 1;
    for (var y = 0.0; y < h; y += 6) {
      canvas.drawLine(Offset(w / 2, y), Offset(w / 2, math.min(h, y + 2)), dash);
    }
    for (var x = 0.0; x < w; x += 6) {
      canvas.drawLine(Offset(x, h / 2), Offset(math.min(w, x + 2), h / 2), dash);
    }
    for (var i = 0; i < trail.length; i++) {
      final q = trail[i];
      paintBlob(canvas, q.p, 10, spectrum[i % spectrum.length], 0.12 * (1 - q.age / 0.5));
    }
    final on = holding ? 1.0 : 0.45;
    paintBlob(canvas, dot, 46, spectrum[0], 0.5 * on);
    paintBlob(canvas, dot, 26, spectrum[2 % spectrum.length], 0.5 * on);
    paintBlob(canvas, dot, 9, Colors.white, 0.9 * on);
  }

  @override
  bool shouldRepaint(_AimPainter old) => true;
}

class _LensPainter extends CustomPainter {
  _LensPainter({
    required this.t,
    required this.light,
    required this.velocity,
    required this.la,
    required this.spectrum,
  });

  final double t;
  final Offset light;
  final Offset velocity;
  final double la;
  final List<Color> spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    final lw = size.width;
    // Sleeping glow pooled at the bottom of the lens.
    for (var i = 0; i < 4; i++) {
      final x = lw * (0.5 + 0.28 * math.sin(t * (0.5 + i * 0.12) + i * 2));
      canvas.save();
      canvas.translate(x, lw * 1.02);
      canvas.scale(1.5, 0.8);
      paintBlob(canvas, Offset.zero, lw * 0.34, spectrum[i % spectrum.length],
          0.32 + 0.2 * la);
      canvas.restore();
    }
    paintBlob(canvas, light, lw * 0.42, spectrum[1 % spectrum.length], 0.5 * la,
        velocity: velocity);
    paintBlob(canvas, light, lw * 0.22, spectrum[0], 0.7 * la, velocity: velocity);
    paintBlob(canvas, light, lw * 0.08, Colors.white, 0.5 * la);
    // Inner shadow: dark at the top edge, like the CSS inset shadow.
    final r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = const RadialGradient(
          radius: 0.72,
          colors: <Color>[Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
          stops: <double>[0, 0.82, 1],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_LensPainter old) => true;
}
