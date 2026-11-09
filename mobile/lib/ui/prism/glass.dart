import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Black frosted glass (prototype `.glass` / `.glass-strong`): backdrop blur,
/// hairline edge, a top sheen and, when [glow] > 0, a living spectral glow
/// that breathes inside the edge named by [glowAt] (the Siri-like look).
class PrismGlass extends StatefulWidget {
  const PrismGlass({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.glow = 0,
    this.glowAt = Alignment.bottomCenter,
    this.spectrum,
    this.strong = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;

  /// 0..1 intensity of the inner spectral glow.
  final double glow;
  final Alignment glowAt;
  final List<Color>? spectrum;
  final bool strong;

  @override
  State<PrismGlass> createState() => _PrismGlassState();
}

class _PrismGlassState extends State<PrismGlass>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PrismGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.glow > 0) {
      if (!_clock.isAnimating) _clock.repeat();
    } else if (_clock.isAnimating) {
      _clock.stop();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    final strong = widget.strong;
    final blur = strong ? 28.0 : 22.0;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final spectrum = widget.spectrum ?? P.spectrumMac;

    Widget content = Padding(padding: widget.padding, child: widget.child);
    if (widget.glow > 0) {
      content = Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _GlowPainter(
                    clock: _clock,
                    reduce: reduce,
                    glow: widget.glow.clamp(0.0, 1.0),
                    at: widget.glowAt,
                    spectrum: spectrum,
                  ),
                ),
              ),
            ),
          ),
          content,
        ],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: P.shadow,
            blurRadius: 40,
            spreadRadius: -24,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              color: strong ? P.glassStrong : P.glass,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: r,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: <double>[0, strong ? 0.6 : 0.55],
                  colors: const <Color>[P.sheen, Color(0x00FFFFFF)],
                ),
              ),
            child: CustomPaint(
              foregroundPainter: _EdgePainter(widget.radius),
              child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hairline border plus the 0.5px specular highlight on the top edge.
class _EdgePainter extends CustomPainter {
  _EdgePainter(this.radius);

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(math.min(radius, size.shortestSide / 2)),
    );
    canvas.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = P.hair,
    );
    final top = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(size.width, 0),
        <Color>[const Color(0x00FFFFFF), P.spec, const Color(0x00FFFFFF)],
        <double>[0, 0.5, 1],
      );
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, math.min(radius, 14)));
    canvas.drawRRect(rr.deflate(0.25), top);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.radius != radius;
}

/// Three slowly orbiting spectral blobs pressed against one edge.
class _GlowPainter extends CustomPainter {
  _GlowPainter({
    required this.clock,
    required this.reduce,
    required this.glow,
    required this.at,
    required this.spectrum,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final bool reduce;
  final double glow;
  final Alignment at;
  final List<Color> spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = reduce ? 0.0 : clock.value * math.pi * 2;
    final anchor = at.alongSize(size);
    // Tangent runs along the edge, normal points inward.
    final horizontalEdge = at.y.abs() >= at.x.abs();
    final tangent = horizontalEdge ? const Offset(1, 0) : const Offset(0, 1);
    final span = horizontalEdge ? size.width : size.height;
    final depth = horizontalEdge ? size.height : size.width;
    final breath = 0.82 + 0.18 * math.sin(t * 2);
    final r = math.max(span * 0.42, depth * 0.9);

    for (var i = 0; i < 3; i++) {
      final ph = t + i * 2.1;
      final along = math.sin(ph) * span * 0.26 + (i - 1) * span * 0.22;
      final c = anchor + tangent * along;
      final color = spectrum[(i == 1 ? 2 : (i == 2 ? 3 : 0)) % spectrum.length];
      final a = (0.55 * glow * breath).clamp(0.0, 1.0);
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(
          c,
          r,
          <Color>[
            alpha(color, a),
            alpha(color, a * 0.45),
            alpha(color, 0),
          ],
          <double>[0, 0.35, 1],
        );
      canvas.drawRect(Offset.zero & size, paint);
    }
    // A whisper of white at the hottest point keeps the glow luminous.
    final core = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(
        anchor + tangent * (math.sin(t * 1.3) * span * 0.12),
        r * 0.5,
        <Color>[
          alpha(Colors.white, 0.12 * glow * breath),
          alpha(Colors.white, 0),
        ],
      );
    canvas.drawRect(Offset.zero & size, core);
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.glow != glow ||
      old.at != at ||
      old.spectrum != spectrum ||
      old.reduce != reduce;
}
