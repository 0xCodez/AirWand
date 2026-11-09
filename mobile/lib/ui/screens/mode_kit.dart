// Shared building blocks for the Air / Keys / Media / Settings screens
// (MODES team). Everything visual comes from the Prism foundation tokens.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../net/hosts.dart';
import '../../state/scope.dart';
import '../prism/prism.dart';

/// Spectrum of the active computer (Mac / Windows palette).
List<Color> activeSpectrum(AirWandServices s) {
  final h = s.control.host ?? s.hosts.active;
  return P.spectrumFor(h?.os.wire ?? 'mac');
}

PairedHost? activeHost(AirWandServices s) => s.control.host ?? s.hosts.active;

/// Tiny uppercase Martian Mono caption (`.cap` in the prototype).
class Cap extends StatelessWidget {
  const Cap(this.text, {super.key, this.color, this.size = 8.5});

  final String text;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: PT.mono(size).copyWith(
            color: color ?? P.text3,
            letterSpacing: size * 0.07,
            height: 1.4,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
    );
  }
}

TextStyle uiText(double size,
        {FontWeight weight = FontWeight.w500,
        Color color = P.text,
        double tracking = -0.01}) =>
    PT.display(size).copyWith(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: size * tracking,
    );

/// `.press`: springy scale-down while a finger is on it.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onDown,
    this.scale = 0.96,
  });

  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onDown;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    widget.onDown?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: Duration(milliseconds: _down ? 90 : 420),
          curve: _down ? Curves.easeOut : Curves.elasticOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Chrome rim with a prismatic glint (the conic gradient around the lens and
/// the play button).
const List<Color> _chrome = <Color>[
  Color(0xFFF6F7FA),
  Color(0xFF8D9097),
  Color(0xFFFDFDFF),
  Color(0xFF5D6068),
  Color(0xFFE9EBF0),
  Color(0xFFFF7AB8),
  Color(0xFFFFD36B),
  Color(0xFF7CF5C4),
  Color(0xFF77A8FF),
  Color(0xFFE9EBF0),
  Color(0xFF6C6F77),
  Color(0xFFFBFBFD),
  Color(0xFF8A8D95),
  Color(0xFFF6F7FA),
];
const List<double> _chromeStops = <double>[
  0, .09, .16, .26, .37, .41, .43, .45, .47, .51, .63, .74, .86, 1,
];

class ChromeRim extends StatelessWidget {
  const ChromeRim({super.key, required this.child, this.width = 5});

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(
          colors: _chrome,
          stops: _chromeStops,
          transform: GradientRotation(210 * math.pi / 180 - math.pi / 2),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
              color: Color(0x99000000), blurRadius: 50, offset: Offset(0, 20),
              spreadRadius: -20),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(width),
        child: ClipOval(child: child),
      ),
    );
  }
}

Color withA(Color c, double a) => c.withAlpha((a.clamp(0.0, 1.0) * 255).round());

/// A soft additive light blob (radial falloff), optionally stretched along
/// a velocity vector.
void paintBlob(Canvas canvas, Offset p, double r, Color color, double a,
    {Offset velocity = Offset.zero, double stretchScale = 900}) {
  if (a <= 0.002 || r <= 0) return;
  final paint = Paint()
    ..blendMode = BlendMode.plus
    ..shader = RadialGradient(
      colors: <Color>[withA(color, a), withA(color, a * 0.45), withA(color, 0)],
      stops: const <double>[0, 0.45, 1],
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: r));
  final speed = velocity.distance;
  canvas.save();
  canvas.translate(p.dx, p.dy);
  if (speed > 1) {
    final k = math.min(speed / stretchScale, 0.9);
    canvas.rotate(velocity.direction);
    canvas.scale(1 + k, 1 / (1 + k * 0.6));
  }
  canvas.drawCircle(Offset.zero, r, paint);
  canvas.restore();
}

/// `.switch`: hairline track that floods with spectral light when on.
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.spectrum,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final List<Color> spectrum;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: SizedBox(
          width: 50,
          height: 30,
          child: Stack(children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: P.hair2,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: value ? 1 : 0,
                duration: const Duration(milliseconds: 260),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: LinearGradient(
                        colors: spectrum.take(3).toList(growable: false)),
                  ),
                ),
              ),
            ),
            AnimatedAlign(
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              child: Container(
                margin: const EdgeInsets.all(3),
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  color: Color(0xFFF4F4F6),
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                        color: Color(0x4D000000),
                        blurRadius: 6,
                        offset: Offset(0, 2)),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// `.slider`: 3 px hairline track, spectral fill, white knob that grows
/// while dragged. Value is 0..1; the visual follows through a spring.
class ModeSlider extends StatefulWidget {
  const ModeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.spectrum,
    this.onChangeEnd,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final List<Color> spectrum;

  @override
  State<ModeSlider> createState() => _ModeSliderState();
}

class _ModeSliderState extends State<ModeSlider>
    with SingleTickerProviderStateMixin {
  late final SpringValue _vis =
      SpringValue(widget.value, response: 0.16, damping: 0.92);
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  bool _drag = false;
  double _v = 0;

  @override
  void initState() {
    super.initState();
    _v = widget.value;
  }

  @override
  void didUpdateWidget(ModeSlider old) {
    super.didUpdateWidget(old);
    if (!_drag && (widget.value - _v).abs() > 1e-4) {
      _v = widget.value;
      _go();
    }
  }

  void _go() {
    _vis.target = _v;
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration e) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (e - _last).inMicroseconds / 1e6;
    _last = e;
    _vis.step(dt.clamp(0.0, 0.05));
    if (_vis.settled) {
      _vis.snap(_vis.target);
      _ticker.stop();
    }
    setState(() {});
  }

  void _at(Offset local, double width) {
    _v = ((local.dx - 12) / math.max(1, width - 24)).clamp(0.0, 1.0);
    _go();
    widget.onChanged(_v);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final x = _vis.value.clamp(0.0, 1.0);
      final knob = _drag ? 28.0 : 24.0;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          setState(() => _drag = true);
          _at(d.localPosition, w);
        },
        onHorizontalDragUpdate: (d) => _at(d.localPosition, w),
        onHorizontalDragEnd: (_) {
          setState(() => _drag = false);
          widget.onChangeEnd?.call(_v);
        },
        onTapDown: (d) => _at(d.localPosition, w),
        onTapUp: (_) => widget.onChangeEnd?.call(_v),
        child: SizedBox(
          height: 36,
          width: w,
          child: Stack(clipBehavior: Clip.none, children: <Widget>[
            Positioned(
              left: 12,
              right: 12,
              top: 16.5,
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Stack(children: <Widget>[
                  const Positioned.fill(child: ColoredBox(color: P.hair2)),
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: x,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                              colors: widget.spectrum.take(3).toList()),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              left: 12 + x * (w - 24) - knob / 2,
              top: 18 - knob / 2,
              width: knob,
              height: knob,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFFF4F4F6),
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                        color: Color(0x59000000),
                        blurRadius: 10,
                        offset: Offset(0, 3)),
                  ],
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}

/// `.seg`: pill segmented control with a sliding glass well.
class ModeSegmented<T> extends StatelessWidget {
  const ModeSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    const segW = 68.0;
    final i = math.max(0, options.indexWhere((o) => o.$1 == value));
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: P.hair,
        borderRadius: BorderRadius.circular(999),
      ),
      child: SizedBox(
        width: segW * options.length,
        height: 30,
        child: Stack(children: <Widget>[
          AnimatedPositioned(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutBack,
            left: i * segW,
            top: 0,
            bottom: 0,
            width: segW,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x2EFFFFFF), Color(0x14FFFFFF)],
                ),
                border: Border.all(color: P.hair, width: 0.5),
              ),
            ),
          ),
          Row(children: <Widget>[
            for (final o in options)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(o.$1),
                child: SizedBox(
                  width: segW,
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 220),
                      style: uiText(13,
                          weight: FontWeight.w600,
                          color: o.$1 == value ? P.text : P.text3),
                      child: Text(o.$2),
                    ),
                  ),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
