import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'haptics.dart';
import 'motion.dart';
import 'tokens.dart';

/// Press feedback: scale to 0.95 on a spring (prototype `.press`).
class PrismPressable extends StatefulWidget {
  const PrismPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.95,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;

  @override
  State<PrismPressable> createState() => _PrismPressableState();
}

class _PrismPressableState extends State<PrismPressable>
    with TickerProviderStateMixin, SpringTicker<PrismPressable> {
  final SpringValue _s = SpringValue(1, response: 0.38, damping: 0.62);

  @override
  bool get animating => !_s.settled;

  @override
  void onFrame(double dt) => setState(() => _s.step(dt));

  void _to(double v) {
    _s.target = v;
    wake();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _to(widget.scale) : null,
      onTapCancel: enabled ? () => _to(1) : null,
      onTapUp: enabled ? (_) => _to(1) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) Haptic.tick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: Transform.scale(scale: _s.value, child: widget.child),
    );
  }
}

/// 40px glass pill with a spectral glow (host pill, chips in headers).
class PrismPill extends StatelessWidget {
  const PrismPill({
    super.key,
    required this.child,
    this.onTap,
    this.spectrum,
    this.glow = 0.55,
    this.height = 40,
    this.padding = const EdgeInsets.fromLTRB(13, 0, 14, 0),
  });

  final Widget child;
  final VoidCallback? onTap;
  final List<Color>? spectrum;
  final double glow;
  final double height;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final pill = SizedBox(
      height: height,
      child: PrismGlass(
        radius: height / 2,
        strong: true,
        glow: glow,
        spectrum: spectrum,
        padding: padding,
        child: DefaultTextStyle.merge(
          style: PT.label,
          child: IconTheme.merge(
            data: const IconThemeData(color: P.text2, size: 17),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Flexible(child: child),
            ]),
          ),
        ),
      ),
    );
    if (onTap == null) return pill;
    return PrismPressable(onTap: onTap, child: pill);
  }
}

/// Round glass icon button (prototype `.rbtn`).
class PrismIconButton extends StatelessWidget {
  const PrismIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 44,
    this.iconSize = 20,
    this.semanticLabel,
    this.glow = 0,
    this.spectrum,
    this.color = P.text,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final String? semanticLabel;
  final double glow;
  final List<Color>? spectrum;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: PrismPressable(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: size,
          child: PrismGlass(
            radius: size / 2,
            strong: true,
            glow: glow,
            spectrum: spectrum,
            child: Center(
              child: Icon(
                icon,
                size: iconSize,
                color: onPressed == null ? P.text3 : color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 50x30 switch whose track fills with the spectrum when on.
class PrismSwitch extends StatefulWidget {
  const PrismSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.spectrum,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final List<Color>? spectrum;

  @override
  State<PrismSwitch> createState() => _PrismSwitchState();
}

class _PrismSwitchState extends State<PrismSwitch>
    with TickerProviderStateMixin, SpringTicker<PrismSwitch> {
  late final SpringValue _x =
      SpringValue(widget.value ? 1 : 0, response: 0.42, damping: 0.72);

  @override
  bool get animating => !_x.settled;

  @override
  void onFrame(double dt) => setState(() => _x.step(dt));

  @override
  void didUpdateWidget(PrismSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _x.target = widget.value ? 1 : 0;
      wake();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spectrum ?? P.spectrumMac;
    final on = _x.value.clamp(0.0, 1.0);
    return Semantics(
      toggled: widget.value,
      child: GestureDetector(
        onTap: widget.onChanged == null
            ? null
            : () {
                Haptic.tick();
                widget.onChanged!(!widget.value);
              },
        child: SizedBox(
          width: 50,
          height: 30,
          child: Stack(children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: P.hair2,
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
            Positioned.fill(
              child: Opacity(
                opacity: on,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: P.fill(s),
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 3 + 20 * _x.value,
              top: 3,
              child: Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  color: P.knob,
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

/// Thin spectral slider: 3px track, gradient fill, 24px knob growing to 28.
class PrismSlider extends StatefulWidget {
  const PrismSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChangeEnd,
    this.spectrum,
    this.semanticLabel,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChangeEnd;
  final List<Color>? spectrum;
  final String? semanticLabel;

  @override
  State<PrismSlider> createState() => _PrismSliderState();
}

class _PrismSliderState extends State<PrismSlider>
    with TickerProviderStateMixin, SpringTicker<PrismSlider> {
  final SpringValue _knob = SpringValue(24, response: 0.4, damping: 0.7);
  late final SpringValue _pos = SpringValue(_frac(widget.value),
      response: 0.3, damping: 0.9);
  bool _drag = false;
  double _last = double.nan;

  double _frac(double v) {
    final span = widget.max - widget.min;
    if (span <= 0) return 0;
    return ((v - widget.min) / span).clamp(0.0, 1.0);
  }

  @override
  bool get animating => !_knob.settled || !_pos.settled;

  @override
  void onFrame(double dt) => setState(() {
        _knob.step(dt);
        _pos.step(dt);
      });

  @override
  void didUpdateWidget(PrismSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final f = _frac(widget.value);
    if (_drag) {
      _pos.snap(f);
    } else if ((f - _pos.target).abs() > 1e-6) {
      _pos.target = f;
      wake();
    }
  }

  void _set(double dx, double width) {
    var f = ((dx - 12) / math.max(1, width - 24)).clamp(0.0, 1.0);
    final d = widget.divisions;
    if (d != null && d > 0) f = (f * d).round() / d;
    final v = widget.min + f * (widget.max - widget.min);
    if (v != _last) {
      if (d != null && !_last.isNaN) Haptic.tick();
      _last = v;
      widget.onChanged?.call(v);
    }
    _pos.snap(f);
    setState(() {});
  }

  void _grab(bool on) {
    _drag = on;
    _knob.target = on ? 28 : 24;
    wake();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spectrum ?? P.spectrumMac;
    final enabled = widget.onChanged != null;
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: widget.value.toStringAsFixed(2),
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 240.0;
        final f = _pos.value.clamp(0.0, 1.0);
        final k = _knob.value;
        final kx = 12 + f * (w - 24);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) {
                  _grab(true);
                  _set(d.localPosition.dx, w);
                }
              : null,
          onHorizontalDragUpdate:
              enabled ? (d) => _set(d.localPosition.dx, w) : null,
          onHorizontalDragEnd: enabled
              ? (_) {
                  _grab(false);
                  widget.onChangeEnd?.call(widget.value);
                }
              : null,
          onTapDown: enabled
              ? (d) {
                  _set(d.localPosition.dx, w);
                  widget.onChangeEnd?.call(
                      widget.min + _pos.value * (widget.max - widget.min));
                }
              : null,
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
                        widthFactor: f,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                                colors: <Color>[s[0], s[1], s[2]]),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
              Positioned(
                left: kx - k / 2,
                top: 18 - k / 2,
                child: Container(
                  width: k,
                  height: k,
                  decoration: const BoxDecoration(
                    color: P.knob,
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
      }),
    );
  }
}

/// Segmented control with a sliding well indicator (prototype `.seg`).
class PrismSegmented<T> extends StatefulWidget {
  const PrismSegmented({
    super.key,
    required this.values,
    required this.value,
    required this.onChanged,
    required this.labelOf,
  });

  final List<T> values;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T value) labelOf;

  @override
  State<PrismSegmented<T>> createState() => _PrismSegmentedState<T>();
}

class _PrismSegmentedState<T> extends State<PrismSegmented<T>>
    with TickerProviderStateMixin, SpringTicker<PrismSegmented<T>> {
  final List<GlobalKey> _keys = <GlobalKey>[];
  final SpringValue _x = SpringValue(0, response: 0.42, damping: 0.8, epsilon: 0.05);
  final SpringValue _w = SpringValue(0, response: 0.42, damping: 0.8, epsilon: 0.05);
  bool _placed = false;

  @override
  bool get animating => !_x.settled || !_w.settled;

  @override
  void onFrame(double dt) => setState(() {
        _x.step(dt);
        _w.step(dt);
      });

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final i = widget.values.indexOf(widget.value);
      if (i < 0 || i >= _keys.length) return;
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      final parent = context.findRenderObject() as RenderBox?;
      if (box == null || parent == null || !box.hasSize) return;
      final x = box.localToGlobal(Offset.zero, ancestor: parent).dx;
      final w = box.size.width;
      if (!_placed) {
        _placed = true;
        setState(() {
          _x.snap(x);
          _w.snap(w);
        });
      } else if ((x - _x.target).abs() > 0.5 || (w - _w.target).abs() > 0.5) {
        _x.target = x;
        _w.target = w;
        wake();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    while (_keys.length < widget.values.length) {
      _keys.add(GlobalKey());
    }
    _measure();
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: P.hair,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Stack(children: <Widget>[
        if (_placed)
          Positioned(
            left: _x.value - 3,
            top: 0,
            bottom: 0,
            width: math.max(0, _w.value),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[P.wellTop, P.wellBot],
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                      color: P.shadow,
                      blurRadius: 8,
                      spreadRadius: -3,
                      offset: Offset(0, 3)),
                ],
              ),
            ),
          ),
        Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          for (var i = 0; i < widget.values.length; i++)
            GestureDetector(
              key: _keys[i],
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (widget.values[i] == widget.value) return;
                Haptic.tick();
                widget.onChanged(widget.values[i]);
              },
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                child: Text(
                  widget.labelOf(widget.values[i]),
                  style: PT.label.copyWith(
                    fontSize: 13,
                    color: widget.values[i] == widget.value ? P.text : P.text3,
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

/// Small glass chip; selected chips carry a spectral underglow.
class PrismChip extends StatelessWidget {
  const PrismChip({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    this.onTap,
    this.spectrum,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;
  final List<Color>? spectrum;

  @override
  Widget build(BuildContext context) {
    return PrismPressable(
      onTap: onTap,
      child: SizedBox(
        height: 34,
        child: PrismGlass(
          radius: 17,
          strong: selected,
          glow: selected ? 0.6 : 0,
          spectrum: spectrum,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 15, color: selected ? P.text : P.text2),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: PT.label.copyWith(
                fontSize: 13,
                color: selected ? P.text : P.text2,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The thin tick-ring dial from the prototype: 48 ticks (majors every 12),
/// a dark sphere, a white wedge showing [fraction] and four mono labels.
class TickDial extends StatelessWidget {
  const TickDial({
    super.key,
    this.size = 200,
    this.fraction = 0,
    this.labels = const <String>['TRACK', 'AIR', 'MEDIA', 'KEYS'],
    this.spectrum,
    this.child,
  });

  final double size;

  /// 0..1 sweep of the white wedge (0 hides it).
  final double fraction;
  final List<String> labels;
  final List<Color>? spectrum;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: TickDialPainter(
          fraction: fraction,
          labels: labels,
          spectrum: spectrum,
          labelStyle: PT.mono(7.5).copyWith(color: const Color(0xD9FFFFFF)),
        ),
        child: child == null ? null : Center(child: child),
      ),
    );
  }
}

class TickDialPainter extends CustomPainter {
  TickDialPainter({
    required this.fraction,
    required this.labels,
    required this.labelStyle,
    this.spectrum,
  });

  final double fraction;
  final List<String> labels;
  final TextStyle labelStyle;
  final List<Color>? spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 200;
    canvas.save();
    canvas.translate((size.width - 200 * s) / 2, (size.height - 200 * s) / 2);
    canvas.scale(s);
    const c = Offset(100, 100);
    canvas.drawCircle(
        c,
        84,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = const Color(0x4DFFFFFF));
    final tick = Paint()..strokeCap = StrokeCap.round;
    for (var k = 0; k < 48; k++) {
      final a = k / 48 * math.pi * 2 - math.pi / 2;
      final major = k % 12 == 0;
      final r1 = major ? 86.5 : 88.0, r2 = major ? 95.0 : 91.0;
      tick
        ..strokeWidth = major ? 1.3 : 0.7
        ..color = alpha(Colors.white, major ? 0.95 : 0.45);
      canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * r1,
          c + Offset(math.cos(a), math.sin(a)) * r2, tick);
    }
    // Sphere.
    final sp = spectrum;
    canvas.drawCircle(
        c,
        62,
        Paint()
          ..shader = ui.Gradient.radial(
            const Offset(100, 80),
            62 * 1.24,
            <Color>[
              sp == null ? const Color(0x8C0B0F33) : alpha(sp[0], 0.35),
              const Color(0xEB020208),
              const Color(0xF5000000),
            ],
            <double>[0, 0.72, 1],
          ));
    if (fraction > 0) {
      final f = fraction.clamp(0.02, 0.98);
      final path = Path()
        ..moveTo(100, 100)
        ..arcTo(Rect.fromCircle(center: c, radius: 62), -math.pi / 2,
            f * math.pi * 2, false)
        ..close();
      canvas.drawPath(
          path,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(38, 38),
              const Offset(162, 162),
              <Color>[const Color(0x00FFFFFF), const Color(0xD9FFFFFF)],
            ));
    }
    canvas.drawCircle(
        c,
        62,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = const Color(0x2EFFFFFF));
    const pos = <Offset>[
      Offset(100, 30),
      Offset(171, 102.5),
      Offset(100, 176),
      Offset(29, 102.5),
    ];
    for (var i = 0; i < math.min(4, labels.length); i++) {
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos[i] - Offset(tp.width / 2, tp.height * 0.75));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TickDialPainter old) =>
      old.fraction != fraction ||
      old.labels != labels ||
      old.spectrum != spectrum ||
      old.labelStyle != labelStyle;
}
