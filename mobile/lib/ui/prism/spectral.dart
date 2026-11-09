import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion.dart';
import 'tokens.dart';

/// One light under the glass. Callers pass spring-smoothed positions.
@immutable
class SpectralLight {
  const SpectralLight({
    required this.id,
    required this.pos,
    this.radius = 46,
    this.intensity = 1,
    this.velocity = Offset.zero,
  });

  final int id;

  /// Local position in the [SpectralField]'s coordinate space.
  final Offset pos;
  final double radius;

  /// 0..1.
  final double intensity;

  /// px/s, stretches the light along its motion.
  final Offset velocity;
}

class _Light {
  _Light(this.id, this.pos) : a = SpringValue(0, response: 0.32, damping: 0.9);

  final int id;
  Offset pos;
  double radius = 46;
  Offset velocity = Offset.zero;
  final SpringValue a;
  bool live = true;
}

class _Ripple {
  _Ripple(this.pos, this.seed)
      : p = SpringValue(0, response: 0.55, damping: 0.9, epsilon: 0.0005) {
    p.target = 1;
  }

  final Offset pos;
  final int seed;
  final SpringValue p;
  double age = 0;

  double get fade {
    final u = (age / 1.05).clamp(0.0, 1.0);
    return (1 - u) * (1 - u);
  }
}

class _Sweep {
  _Sweep(this.dir)
      : p = SpringValue(0, response: 0.9, damping: 0.96, epsilon: 0.0005) {
    p.target = 1;
  }

  final int dir;
  final SpringValue p;
  double age = 0;

  double get progress => p.value.clamp(0.0, 1.0);
  double get envelope => math.sin(math.pi * progress);
}

/// Drives a [SpectralField]: lights, tap ripples, the computer-switch prism
/// sweep, the active spectrum and the idle sleeping glow.
class SpectralController extends ChangeNotifier {
  SpectralController({List<Color> spectrum = P.spectrumMac})
      : _target = List<Color>.of(spectrum),
        _current = List<Color>.of(spectrum);

  static const int maxLights = 5;
  static const int maxRipples = 4;

  final Map<int, _Light> _lights = <int, _Light>{};
  final List<_Ripple> _ripples = <_Ripple>[];
  _Sweep? _sweep;
  List<Color> _target;
  final List<Color> _current;
  int _seq = 0;
  double _time = 0;
  final SpringValue _edge = SpringValue(0, response: 0.6, damping: 1);
  Offset _focus = Offset.zero;
  final SpringValue _idle = SpringValue(1, response: 0.9, damping: 1);

  /// Whether the sleeping glow shows when no finger is down.
  bool idleGlow = true;

  /// Reduced motion: no sweep, frozen swirl.
  bool reduceMotion = false;

  List<Color> get spectrum => List<Color>.unmodifiable(_current);

  /// Cross-fades to a new spectrum (e.g. the next computer's).
  set spectrum(List<Color> colors) {
    if (colors.length < 4) return;
    _target = List<Color>.of(colors);
  }

  /// Replace the set of lights. Lights missing from [lights] fade out.
  void setLights(List<SpectralLight> lights) {
    final seen = <int>{};
    for (final l in lights.take(maxLights)) {
      seen.add(l.id);
      final s = _lights.putIfAbsent(l.id, () {
        _seq++;
        return _Light(l.id, l.pos);
      });
      s.pos = l.pos;
      s.radius = l.radius;
      s.velocity = l.velocity;
      s.live = true;
      s.a.target = l.intensity.clamp(0.0, 1.0);
    }
    for (final s in _lights.values) {
      if (!seen.contains(s.id)) {
        s.live = false;
        s.a.target = 0;
      }
    }
  }

  /// Tap ripple: a spectral ring that blooms from [at].
  void ripple(Offset at) {
    if (_ripples.length >= maxRipples) _ripples.removeAt(0);
    _ripples.add(_Ripple(at, (_seq++) % 4));
  }

  /// Prism sweep across the pad. [dir] > 0 sweeps right to left.
  void sweep(int dir) {
    if (reduceMotion) return;
    _sweep = _Sweep(dir >= 0 ? 1 : -1);
  }

  /// Advance by [dt] seconds. Called by [SpectralField] each frame.
  void tick(double dt, Size size) {
    if (!reduceMotion) _time += dt;
    final k = 1 - math.exp(-dt * 4);
    for (var i = 0; i < 4; i++) {
      _current[i] = Color.lerp(_current[i], _target[i], k)!;
    }
    final dead = <int>[];
    var fx = 0.0, fy = 0.0, fw = 0.0;
    for (final l in _lights.values) {
      l.a.step(dt);
      if (!l.live) {
        l.velocity = l.velocity * math.exp(-dt * 8);
        if (l.a.value < 0.004 && l.a.velocity.abs() < 0.02) dead.add(l.id);
      }
      final w = l.a.value.clamp(0.0, 1.0);
      fx += l.pos.dx * w;
      fy += l.pos.dy * w;
      fw += w;
    }
    dead.forEach(_lights.remove);
    if (fw > 0) _focus = Offset(fx / fw, fy / fw);
    _edge.target = math.min(1.0, fw);
    _edge.step(dt);
    for (var i = _ripples.length - 1; i >= 0; i--) {
      final r = _ripples[i]..p.step(dt);
      r.age += dt;
      if (r.age > 1.1) _ripples.removeAt(i);
    }
    final s = _sweep;
    if (s != null) {
      s.p.step(dt);
      s.age += dt;
      if (s.age > 1.6) _sweep = null;
    }
    _idle.target = (idleGlow && _lights.isEmpty) ? 1 : 0;
    _idle.step(dt);
    notifyListeners();
  }

  int _edgeId(Size size) {
    final d = <double>[
      _focus.dx,
      _focus.dy,
      size.width - _focus.dx,
      size.height - _focus.dy,
    ];
    var best = 0;
    for (var i = 1; i < 4; i++) {
      if (d[i] < d[best]) best = i;
    }
    return best;
  }
}

/// Spectral light rendered under black glass. Uses the fragment shader at
/// `shaders/spectral.frag`, or a sprite painter if the shader fails to load.
class SpectralField extends StatefulWidget {
  const SpectralField({
    super.key,
    required this.controller,
    this.child,
    this.background = P.pad,
  });

  final SpectralController controller;
  final Widget? child;
  final Color background;

  @override
  State<SpectralField> createState() => _SpectralFieldState();
}

class _SpectralFieldState extends State<SpectralField>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _load;
  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _load ??= ui.FragmentProgram.fromAsset('shaders/spectral.frag')
        .then<ui.FragmentProgram?>((p) => p)
        .catchError((Object e) {
      debugPrint('Prism: spectral shader unavailable, using sprites ($e)');
      return null;
    });
    _load!.then((p) {
      if (!mounted || p == null) return;
      setState(() {
        _program = p;
        _shader = p.fragmentShader();
      });
    });
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.controller.reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.1) dt = 1 / 60;
    widget.controller.tick(dt, _size);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _size = c.biggest;
      return RepaintBoundary(
        child: CustomPaint(
          painter: _program != null && _shader != null
              ? _ShaderPainter(widget.controller, _shader!, widget.background)
              : _SpritePainter(widget.controller, widget.background),
          child: widget.child ?? const SizedBox.expand(),
        ),
      );
    });
  }
}

// Color.red/green/blue work on every Flutter >= 3.22 (deprecated from 3.27).
// ignore_for_file: deprecated_member_use
void _rgb(ui.FragmentShader s, int i, Color c) {
  s.setFloat(i, c.red / 255);
  s.setFloat(i + 1, c.green / 255);
  s.setFloat(i + 2, c.blue / 255);
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter(this.c, this.shader, this.bg) : super(repaint: c);

  final SpectralController c;
  final ui.FragmentShader shader;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);
    final s = shader;
    s.setFloat(0, size.width);
    s.setFloat(1, size.height);
    s.setFloat(2, c._time);
    s.setFloat(3, c._idle.value.clamp(0.0, 1.0));
    for (var i = 0; i < 4; i++) {
      _rgb(s, 4 + i * 3, c._current[i]);
    }
    final lights = c._lights.values.toList();
    for (var i = 0; i < SpectralController.maxLights; i++) {
      final l = i < lights.length ? lights[i] : null;
      final b = 16 + i * 4, v = 36 + i * 4;
      s.setFloat(b, l?.pos.dx ?? 0);
      s.setFloat(b + 1, l?.pos.dy ?? 0);
      s.setFloat(b + 2, l?.radius ?? 0);
      s.setFloat(b + 3, l == null ? 0 : l.a.value.clamp(0.0, 1.2));
      s.setFloat(v, l?.velocity.dx ?? 0);
      s.setFloat(v + 1, l?.velocity.dy ?? 0);
      s.setFloat(v + 2, (l?.id ?? 0).toDouble());
      s.setFloat(v + 3, 0);
    }
    for (var i = 0; i < SpectralController.maxRipples; i++) {
      final r = i < c._ripples.length ? c._ripples[i] : null;
      final b = 56 + i * 4;
      s.setFloat(b, r?.pos.dx ?? 0);
      s.setFloat(b + 1, r?.pos.dy ?? 0);
      s.setFloat(b + 2, r?.p.value ?? 0);
      s.setFloat(b + 3, r?.fade ?? 0);
    }
    final sw = c._sweep;
    s.setFloat(72, sw?.progress ?? 0);
    s.setFloat(73, (sw?.dir ?? 1).toDouble());
    s.setFloat(74, sw?.envelope ?? 0);
    s.setFloat(75, 0);
    s.setFloat(76, c._focus.dx);
    s.setFloat(77, c._focus.dy);
    s.setFloat(78, c._edge.value.clamp(0.0, 1.0));
    s.setFloat(79, c._edgeId(size).toDouble());
    canvas.drawRect(rect, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(_ShaderPainter old) =>
      old.c != c || old.shader != shader || old.bg != bg;
}

/// Fallback: pre-blurred radial sprites composited with [BlendMode.plus].
class _SpritePainter extends CustomPainter {
  _SpritePainter(this.c, this.bg) : super(repaint: c);

  final SpectralController c;
  final Color bg;

  static final Map<int, Shader> _sprites = <int, Shader>{};

  static Shader _sprite(Color col) {
    final key = (col.red & 248) << 16 | (col.green & 248) << 8 | (col.blue & 248);
    final hit = _sprites[key];
    if (hit != null) return hit;
    if (_sprites.length > 360) _sprites.clear();
    final base = Color(0xFF000000 | key);
    const stops = <double>[0, 0.12, 0.28, 0.45, 0.62, 0.8, 1];
    const alphas = <double>[1, 0.88, 0.6, 0.32, 0.13, 0.035, 0];
    final s = ui.Gradient.radial(
      Offset.zero,
      1,
      <Color>[for (final a in alphas) alpha(base, a)],
      stops,
    );
    _sprites[key] = s;
    return s;
  }

  void _blob(Canvas canvas, Offset at, double r, Color col, double a,
      {double angle = 0, double sx = 1, double sy = 1}) {
    if (a <= 0.002 || r <= 0.5) return;
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = _sprite(col)
      ..color = Color.fromRGBO(0, 0, 0, a.clamp(0.0, 1.0));
    canvas.save();
    canvas.translate(at.dx, at.dy);
    if (angle != 0) canvas.rotate(angle);
    canvas.scale(r * sx, r * sy);
    canvas.drawCircle(Offset.zero, 1, paint);
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);
    canvas.save();
    canvas.clipRect(rect);
    canvas.saveLayer(rect, Paint());
    final spec = c._current;
    final t = c._time;
    final white = const Color(0xFFFFFFFF);

    // Idle sleeping glow.
    final idle = c._idle.value.clamp(0.0, 1.0);
    if (idle > 0.002) {
      final breath = 0.78 + 0.22 * math.sin(t * 0.9);
      for (var i = 0; i < 3; i++) {
        final x = size.width * (0.3 + 0.2 * i) +
            math.sin(t * 0.37 + i * 2.1) * size.width * 0.12;
        _blob(canvas, Offset(x, size.height + 10), size.width * 0.42,
            spec[i == 0 ? 0 : i + 1], 0.55 * idle * breath,
            sx: 1, sy: 0.55);
      }
    }

    // Edge bleed.
    final edge = c._edge.value.clamp(0.0, 1.0);
    if (edge > 0.002) {
      final f = c._focus;
      final id = c._edgeId(size);
      final at = switch (id) {
        0 => Offset(0, f.dy),
        1 => Offset(f.dx, 0),
        2 => Offset(size.width, f.dy),
        _ => Offset(f.dx, size.height),
      };
      final vertical = id == 0 || id == 2;
      _blob(canvas, at, 150, spec[(t * 0.4).floor() % 4], 0.35 * edge,
          sx: vertical ? 0.22 : 1, sy: vertical ? 1 : 0.22);
    }

    final lights = c._lights.values.toList();
    // Metaball bridges between close lights.
    for (var i = 0; i < lights.length; i++) {
      for (var j = i + 1; j < lights.length; j++) {
        final a = lights[i].pos, b = lights[j].pos;
        final d = (b - a).distance;
        if (d > 300 || d < 2) continue;
        final st = 1 - d / 300;
        final al = math.min(lights[i].a.value, lights[j].a.value);
        final n = (d / 12).ceil();
        final neck = ((d - 50) / 230).clamp(0.0, 0.72);
        for (var s = 1; s < n; s++) {
          final u = s / n;
          final r = 46 * (1 - neck * math.sin(math.pi * u));
          _blob(canvas, Offset.lerp(a, b, u)!, r,
              Color.lerp(spec[lights[i].id % 4], spec[lights[j].id % 4], u)!,
              0.13 * al * (0.35 + 0.65 * st));
        }
      }
    }

    // Lights: a white-hot core with spectral layers swirling around it.
    for (final l in lights) {
      final a = l.a.value.clamp(0.0, 1.2);
      if (a <= 0.004) continue;
      final sp = l.velocity.distance;
      final stretch = 1 + (sp / 700).clamp(0.0, 1.0) * 1.3;
      final ang = sp > 1 ? math.atan2(l.velocity.dy, l.velocity.dx) : 0.0;
      final calm = 1 - (sp / 700).clamp(0.0, 1.0);
      final k = l.id % 4;
      final ph = t * 1.25 + l.id * 1.7;
      final r = l.radius;
      final mid = l.pos + Offset(math.cos(ph) * 24 * calm, math.sin(ph * 1.13) * 18 * calm);
      final tail = mid +
          Offset(math.cos(-ph * 0.8 + 2) * 36 * calm,
              math.sin(-ph * 0.7 + 2) * 28 * calm);
      _blob(canvas, tail, r * 2.3, spec[(k + 2) % 4], 0.42 * a,
          angle: ang, sx: stretch, sy: 1 / stretch);
      _blob(canvas, mid, r * 1.8, spec[(k + 1) % 4], 0.55 * a,
          angle: ang, sx: stretch, sy: 1 / stretch);
      _blob(canvas, l.pos, r * 1.35, spec[k], 0.75 * a,
          angle: ang, sx: stretch, sy: 1 / stretch);
      _blob(canvas, l.pos, r * 0.55, Color.lerp(spec[k], white, 0.6)!, 0.6 * a);
    }

    // Ripples.
    for (final rp in c._ripples) {
      final q = rp.p.value.clamp(0.0, 1.15);
      final radius = 9 + q * 70;
      final fade = rp.fade;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 + 12 * (1 - math.min(1.0, q))
        ..blendMode = BlendMode.plus
        ..shader = SweepGradient(
          transform: GradientRotation(t * 2.2 + rp.seed),
          colors: <Color>[
            for (var i = 0; i < 5; i++) alpha(spec[(rp.seed + i) % 4], 0.45 * fade),
          ],
        ).createShader(Rect.fromCircle(center: rp.pos, radius: radius));
      canvas.drawCircle(rp.pos, radius, ring);
      _blob(canvas, rp.pos, 26 + 26 * q, Color.lerp(spec[rp.seed], white, 0.45)!,
          0.6 * math.exp(-rp.age * 6));
    }

    // Prism sweep.
    final sw = c._sweep;
    if (sw != null) {
      final env = sw.envelope;
      final u = sw.progress;
      final x = sw.dir > 0
          ? ui.lerpDouble(size.width * 1.3, -size.width * 0.3, u)!
          : ui.lerpDouble(-size.width * 0.3, size.width * 1.3, u)!;
      final disp = 8 + 30 * env;
      for (var i = 0; i < P.prismBands.length; i++) {
        _blob(canvas, Offset(x + (i - 3) * disp * -sw.dir, size.height * 0.5),
            size.height * 0.62, P.prismBands[i], 0.8 * env,
            angle: 0.1 * sw.dir, sx: 0.2, sy: 1);
      }
      _blob(canvas, Offset(x, size.height * 0.5), size.height * 0.55, white,
          0.3 * env,
          angle: 0.1 * sw.dir, sx: 0.07, sy: 1);
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpritePainter old) => old.c != c || old.bg != bg;
}
