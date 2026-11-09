import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../net/protocol.dart';
import '../../state/scope.dart';
import '../prism/prism.dart';
import 'mode_kit.dart';

/// Media: source card, transport with a chrome play button whose icon
/// morphs, a relative volume slider (sends volume steps), and Presenter.
class MediaView extends StatefulWidget {
  const MediaView({super.key, this.topInset = 0, this.bottomInset = 0});

  final double topInset;
  final double bottomInset;

  @override
  State<MediaView> createState() => _MediaViewState();
}

/// One volume step on the host is ~6.25 % (16 steps, as on macOS).
const double _step = 1 / 16;

class _MediaViewState extends State<MediaView> with TickerProviderStateMixin {
  late final AnimationController _pp = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420), value: 1);
  late final AnimationController _breath = AnimationController(
      vsync: this, duration: const Duration(seconds: 6))
    ..repeat();
  bool _playing = false;
  bool _muted = false;
  double _vol = 0.5;
  int _lastStep = 8;
  bool _presenter = false;
  String _status = 'Ready';
  int _slides = 0;
  int _flash = 0;
  Timer? _flashT;

  AirWandServices get _s => AirWandScope.of(context);

  @override
  void dispose() {
    _pp.dispose();
    _breath.dispose();
    _flashT?.cancel();
    super.dispose();
  }

  void _media(int id) {
    final s = _s;
    s.control.media(id);
    s.haptics.light();
    setState(() {
      switch (id) {
        case MediaId.playPause:
          _playing = !_playing;
          _pp.forward(from: 0);
          _status = _playing ? 'Play' : 'Pause';
        case MediaId.next:
          _status = 'Next track';
        case MediaId.previous:
          _status = 'Previous track';
        case MediaId.mute:
          _muted = !_muted;
          _status = _muted ? 'Muted' : 'Sound on';
      }
    });
  }

  void _volume(double v) {
    final s = _s;
    final step = (v / _step).round();
    if (step != _lastStep) {
      final up = step > _lastStep;
      for (var i = 0; i < (step - _lastStep).abs(); i++) {
        s.control.media(up ? MediaId.volumeUp : MediaId.volumeDown);
      }
      _lastStep = step;
      s.haptics.selection();
      _status = up ? 'Volume up' : 'Volume down';
    }
    setState(() {
      _vol = v;
      if (_muted && v > 0) _muted = false;
    });
  }

  void _slide(int dir) {
    final s = _s;
    s.control.key(dir > 0 ? Hid.right : Hid.left);
    s.haptics.medium();
    _flashT?.cancel();
    setState(() {
      _slides += dir;
      _flash = dir;
    });
    _flashT = Timer(const Duration(milliseconds: 110), () {
      if (mounted) setState(() => _flash = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final spectrum = activeSpectrum(s);
    final host = activeHost(s);
    final pad = EdgeInsets.fromLTRB(14, widget.topInset + 2, 14, widget.bottomInset);
    return Stack(children: <Widget>[
      Padding(
        padding: pad,
        child: Column(children: <Widget>[
          PrismGlass(
            radius: 24,
            spectrum: spectrum,
            padding: const EdgeInsets.all(14),
            child: Row(children: <Widget>[
              _Art(spectrum: spectrum, breath: _breath),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_playing ? 'Playing' : 'Now playing',
                        style: uiText(21, weight: FontWeight.w700, tracking: -0.03)),
                    const SizedBox(height: 4),
                    Text('System media · on ${host?.name ?? 'your computer'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: uiText(13, color: P.text2)),
                    const SizedBox(height: 8),
                    Cap(_status),
                  ],
                ),
              ),
            ]),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                _RoundBtn(
                  icon: Icons.skip_previous_rounded,
                  label: 'Previous track',
                  onTap: () => _media(MediaId.previous),
                ),
                const SizedBox(width: 26),
                Semantics(
                  button: true,
                  label: 'Play or pause',
                  child: Pressable(
                    onTap: () => _media(MediaId.playPause),
                    child: SizedBox.square(
                      dimension: 104,
                      child: ChromeRim(
                        width: 4,
                        child: Stack(fit: StackFit.expand, children: <Widget>[
                          const ColoredBox(color: P.glassStrong),
                          CustomPaint(
                            painter: _PlayGlowPainter(spectrum, _breath),
                          ),
                          Center(
                            child: AnimatedBuilder(
                              animation: _pp,
                              builder: (context, _) => CustomPaint(
                                size: const Size(34, 34),
                                painter: _PlayPausePainter(
                                  t: Curves.easeOutBack.transform(_pp.value),
                                  toPause: _playing,
                                ),
                              ),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 26),
                _RoundBtn(
                  icon: Icons.skip_next_rounded,
                  label: 'Next track',
                  onTap: () => _media(MediaId.next),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 58,
            child: PrismGlass(
              radius: 22,
              spectrum: spectrum,
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
              child: Row(children: <Widget>[
                Pressable(
                  onTap: () => _media(MediaId.mute),
                  child: SizedBox.square(
                    dimension: 42,
                    child: Icon(
                      _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                      size: 20,
                      color: P.text,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ModeSlider(
                    value: _muted ? 0 : _vol,
                    spectrum: spectrum,
                    onChanged: _volume,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 26,
                  child: Text('${_muted ? 0 : (_vol * 100).round()}',
                      textAlign: TextAlign.right,
                      style: uiText(13, color: P.text2)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: PrismGlass(
              radius: 20,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: <Widget>[
                const Icon(Icons.co_present_outlined, size: 20, color: P.text2),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Presenter', style: uiText(15, weight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('Two giant Back and Next areas',
                          style: uiText(12, color: P.text3)),
                    ],
                  ),
                ),
                ModeSwitch(
                  value: _presenter,
                  spectrum: spectrum,
                  onChanged: (v) {
                    if (v) s.haptics.light();
                    setState(() => _presenter = v);
                  },
                ),
              ]),
            ),
          ),
        ]),
      ),
      if (_presenter)
        Positioned.fill(
          child: ColoredBox(
            color: P.bg,
            child: Padding(
              padding: pad,
              child: Column(children: <Widget>[
                Expanded(
                  child: _Zone(
                    title: 'Back',
                    caption: 'Previous slide',
                    top: true,
                    flash: _flash < 0,
                    colors: <Color>[spectrum[0], spectrum[3 % spectrum.length]],
                    onTap: () => _slide(-1),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _Zone(
                    title: 'Next',
                    caption: 'Next slide',
                    top: false,
                    flash: _flash > 0,
                    colors: <Color>[spectrum[2 % spectrum.length], spectrum[1]],
                    onTap: () => _slide(1),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 0, 4),
                  child: Row(children: <Widget>[
                    Expanded(
                      child: Cap(_slides == 0
                          ? 'Arrow keys · ← →'
                          : 'Moved ${_slides > 0 ? '+' : ''}$_slides slides'),
                    ),
                    Pressable(
                      onTap: () => setState(() => _presenter = false),
                      child: SizedBox(
                        height: 46,
                        child: PrismGlass(
                          radius: 999,
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          child: Center(
                            child: Text('Done', style: uiText(14, weight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 62,
          child: Icon(icon, size: 32, color: P.text),
        ),
      ),
    );
  }
}

class _Art extends StatelessWidget {
  const _Art({required this.spectrum, required this.breath});
  final List<Color> spectrum;
  final Animation<double> breath;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox.square(
        dimension: 66,
        child: AnimatedBuilder(
          animation: breath,
          builder: (context, _) => CustomPaint(
            painter: _ArtPainter(spectrum, breath.value),
          ),
        ),
      ),
    );
  }
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(this.s, this.t);
  final List<Color> s;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, 1),
          radius: 0.9,
          colors: <Color>[s[1], s[0]],
        ).createShader(r),
    );
    final a = t * 2 * math.pi;
    final w = size.width;
    paintBlob(canvas, Offset(w * (0.3 + 0.08 * math.sin(a)), w * (0.3 + 0.06 * math.cos(a))),
        w * 0.6, s[3 % s.length], 0.95);
    paintBlob(canvas, Offset(w * (0.8 - 0.07 * math.cos(a)), w * (0.7 + 0.05 * math.sin(a))),
        w * 0.6, s[2 % s.length], 0.9);
  }

  @override
  bool shouldRepaint(_ArtPainter old) => old.t != t || old.s != s;
}

class _PlayGlowPainter extends CustomPainter {
  _PlayGlowPainter(this.s, this.anim) : super(repaint: anim);
  final List<Color> s;
  final Animation<double> anim;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final a = anim.value * 2 * math.pi;
    final xs = <double>[0.3, 0.55, 0.78];
    final cs = <Color>[s[0], s[2 % s.length], s[3 % s.length]];
    for (var i = 0; i < 3; i++) {
      canvas.save();
      canvas.translate(w * (xs[i] + 0.04 * math.sin(a + i * 2)), w * 1.02);
      canvas.scale(1.3, 0.9);
      paintBlob(canvas, Offset.zero, w * 0.36, cs[i], 0.75);
      canvas.restore();
    }
    final r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: <Color>[Color(0x73000000), Color(0x00000000)],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_PlayGlowPainter old) => old.s != s;
}

/// Morphs two quads between the play triangle and the pause bars, in the
/// prototype's 24-unit icon space.
class _PlayPausePainter extends CustomPainter {
  _PlayPausePainter({required this.t, required this.toPause});
  final double t;
  final bool toPause;

  static const List<List<Offset>> _play = <List<Offset>>[
    <Offset>[Offset(7, 4.6), Offset(13, 8.3), Offset(13, 15.7), Offset(7, 19.4)],
    <Offset>[Offset(13, 8.3), Offset(19.2, 12), Offset(19.2, 12), Offset(13, 15.7)],
  ];
  static const List<List<Offset>> _pause = <List<Offset>>[
    <Offset>[Offset(6.5, 5), Offset(10, 5), Offset(10, 19), Offset(6.5, 19)],
    <Offset>[Offset(14, 5), Offset(17.5, 5), Offset(17.5, 19), Offset(14, 19)],
  ];

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  void paint(Canvas canvas, Size size) {
    final from = toPause ? _play : _pause;
    final to = toPause ? _pause : _play;
    final k = size.width / 24;
    final paint = Paint()..color = P.text;
    for (var q = 0; q < 2; q++) {
      final path = Path();
      for (var j = 0; j < 4; j++) {
        final p = Offset(
          _lerp(from[q][j].dx, to[q][j].dx, t) * k,
          _lerp(from[q][j].dy, to[q][j].dy, t) * k,
        );
        if (j == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_PlayPausePainter old) => old.t != t || old.toPause != toPause;
}

class _Zone extends StatelessWidget {
  const _Zone({
    required this.title,
    required this.caption,
    required this.top,
    required this.flash,
    required this.colors,
    required this.onTap,
  });

  final String title;
  final String caption;
  final bool top;
  final bool flash;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.98,
      onTap: onTap,
      child: PrismGlass(
        radius: 28,
        child: Stack(fit: StackFit.expand, children: <Widget>[
          AnimatedOpacity(
            opacity: flash ? 0.75 : 0,
            duration: Duration(milliseconds: flash ? 60 : 420),
            child: CustomPaint(painter: _ZoneGlow(colors, top)),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Cap(caption),
                Text(title,
                    style: uiText(44, weight: FontWeight.w700, tracking: -0.04)
                        .copyWith(height: 0.95)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _ZoneGlow extends CustomPainter {
  _ZoneGlow(this.c, this.top);
  final List<Color> c;
  final bool top;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final y = top ? 0.0 : h;
    for (var i = 0; i < 2; i++) {
      canvas.save();
      canvas.translate(w * (i == 0 ? 0.3 : 0.7), y);
      canvas.scale(1.6, 1);
      paintBlob(canvas, Offset.zero, h * 0.55, c[i], 0.9);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ZoneGlow old) => old.c != c || old.top != top;
}
