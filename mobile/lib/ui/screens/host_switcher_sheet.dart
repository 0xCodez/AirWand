// Host switcher: 3D coverflow of tall iridescent computer cards with
// perspective, chromatic edge smear, flick-with-momentum springs and an
// "Add computer" card. Port of b-prism.html "Host switcher: coverflow".

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:airwand/ui/prism/prism.dart';

import '../../net/control.dart';
import '../../net/hosts.dart';
import '../../net/protocol.dart';
import '../../state/scope.dart';
import 'discovery_screen.dart';

const double _tau = math.pi * 2;

Color _alpha(Color c, double o) => c.withAlpha((o.clamp(0.0, 1.0) * 255).round());

Widget _cap(String s, {Color? color, TextAlign? align}) => Text(
      s.toUpperCase(),
      textAlign: align,
      style: PT.cap.copyWith(color: color ?? P.text3),
    );

enum HostSwitcherAction { add, settings }

/// Opens the coverflow.
///
/// Simple form `showHostSwitcher(context)`: picking a card makes that host
/// active in the [HostStore] (the control screen reconnects), and "Add
/// computer" pushes [DiscoveryScreen]; completes with null.
///
/// With [onSelect], picks are reported to the caller instead and "Add
/// computer" completes the future with [HostSwitcherAction.add].
Future<HostSwitcherAction?> showHostSwitcher(
  BuildContext context, {
  ValueChanged<String>? onSelect,
  bool Function(String id)? isOnline,
}) async {
  final nav = Navigator.of(context);
  final action = await nav.push<HostSwitcherAction>(
    PageRouteBuilder<HostSwitcherAction>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 620),
      reverseTransitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (context, animation, secondary) => _HostSwitcher(
        animation: animation,
        onSelect: onSelect,
        isOnline: isOnline,
      ),
    ),
  );
  if (onSelect != null) return action;
  if (action == HostSwitcherAction.add && nav.mounted) {
    await nav.push<void>(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const DiscoveryScreen(canClose: true),
    ));
  }
  return null;
}

class _SpringCurve extends Curve {
  const _SpringCurve(this.zeta);

  final double zeta;

  @override
  double transformInternal(double t) {
    const w0 = 10.0;
    if (zeta >= 1) return 1 - (1 + w0 * t) * math.exp(-w0 * t);
    final wd = w0 * math.sqrt(1 - zeta * zeta);
    return 1 -
        math.exp(-zeta * w0 * t) *
            (math.cos(wd * t) + (zeta * w0 / wd) * math.sin(wd * t));
  }
}

class _HostSwitcher extends StatefulWidget {
  const _HostSwitcher({required this.animation, this.onSelect, this.isOnline});

  final Animation<double> animation;
  final ValueChanged<String>? onSelect;
  final bool Function(String id)? isOnline;

  @override
  State<_HostSwitcher> createState() => _HostSwitcherState();
}

class _HostSwitcherState extends State<_HostSwitcher>
    with SingleTickerProviderStateMixin {
  late final AirWandServices _s = AirWandScope.of(context);
  late final Ticker _ticker;
  late final CurvedAnimation _open = CurvedAnimation(
    parent: widget.animation,
    curve: const _SpringCurve(0.84),
    reverseCurve: Curves.easeInCubic,
  );
  late final CurvedAnimation _content = CurvedAnimation(
    parent: widget.animation,
    curve: const Interval(0.14, 1, curve: _SpringCurve(0.86)),
    reverseCurve: const Interval(0.5, 1, curve: Curves.easeIn),
  );

  /// Card position while settling (flick momentum) and while dragging (stiff).
  final SpringValue _settle = SpringValue(0, response: 0.52, damping: 0.8);
  final SpringValue _follow = SpringValue(0, response: 0.14, damping: 0.95);
  bool _dragging = false;
  double _dragX0 = 0;
  double _dragP0 = 0;
  double _dragMoved = 0;
  double _cw = 220;
  int _index = -1;
  bool _initialised = false;
  bool _closing = false;
  Duration _last = Duration.zero;
  double _t = 0;

  double get _pos => _dragging ? _follow.value : _settle.value;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    Haptic.light();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;
    final ai = math.max(0, _s.hosts.activeIndex).toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _settle.snap(ai);
    } else {
      _settle.snap(ai - 0.9);
      _settle.target = ai;
    }
    _index = ai.round();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _open.dispose();
    _content.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.1) dt = 1 / 60;
    _t += dt;
    if (_dragging) {
      _follow.step(dt);
    } else {
      _settle.step(dt);
    }
    final n = _s.hosts.length + 1;
    final idx = _pos.round().clamp(0, n - 1);
    if (idx != _index) {
      _index = idx;
      Haptic.tick();
    }
    setState(() {});
  }

  // ------------------------------------------------------------ gestures

  double get _spacing => _cw * 0.8;

  void _dragStart(DragStartDetails d) {
    _follow.value = _settle.value;
    _follow.velocity = _settle.velocity;
    _follow.target = _settle.value;
    _dragging = true;
    _dragX0 = d.localPosition.dx;
    _dragP0 = _settle.value;
    _dragMoved = 0;
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final n = _s.hosts.length + 1;
    final dx = d.localPosition.dx - _dragX0;
    _dragMoved = math.max(_dragMoved, dx.abs());
    var target = _dragP0 - dx / _spacing;
    if (target < 0) {
      target *= 0.35;
    } else if (target > n - 1) {
      target = n - 1 + (target - n + 1) * 0.35;
    }
    _follow.target = target;
  }

  void _dragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final n = _s.hosts.length + 1;
    final v = (-d.velocity.pixelsPerSecond.dx / _spacing).clamp(-12.0, 12.0);
    _settle.value = _follow.value;
    _settle.velocity = v;
    final proj = _follow.value + v * 0.2;
    _settle.target = proj.round().clamp(0, n - 1).toDouble();
  }

  void _dragCancel() {
    if (!_dragging) return;
    _dragging = false;
    final n = _s.hosts.length + 1;
    _settle.value = _follow.value;
    _settle.velocity = 0;
    _settle.target = _follow.value.round().clamp(0, n - 1).toDouble();
  }

  void _tapCard(int i) {
    if (i == _index && (_pos - i).abs() < 0.3) {
      _choose(i);
    } else {
      Haptic.tick();
      _settle.target = i.toDouble();
    }
  }

  void _choose(int i) {
    if (_closing) return;
    final hosts = _s.hosts.hosts;
    if (i >= hosts.length) {
      _closing = true;
      Haptic.light();
      Navigator.of(context).pop(HostSwitcherAction.add);
      return;
    }
    final h = hosts[i];
    _closing = true;
    if (h.id != _s.hosts.active?.id) {
      Haptic.medium();
      final cb = widget.onSelect;
      if (cb != null) {
        cb(h.id);
      } else {
        _s.hosts.setActive(h.id);
      }
    } else {
      Haptic.light();
    }
    Navigator.of(context).pop();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    Haptic.tick();
    Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final hosts = _s.hosts.hosts;
    final active = _s.hosts.active;
    final q = _open.value;
    final qc = _content.value.clamp(0.0, 1.0);
    final size = MediaQuery.sizeOf(context);

    // Background morphs out of the host pill at the top centre.
    final sx = ui.lerpDouble(0.46, 1, q)!;
    final sy = ui.lerpDouble(0.055, 1, q)!;
    final radius = ui.lerpDouble(23, 0, q.clamp(0.0, 1.0))!;

    final n = hosts.length + 1;
    final idx = _index.clamp(0, n - 1);
    final atAdd = idx >= hosts.length;
    final current = atAdd ? null : hosts[idx];
    final isActive = current != null && current.id == active?.id;
    final ctaLabel = atAdd
        ? 'Find computers'
        : isActive
            ? (_s.control.state == LinkState.connected ? 'Connected' : 'Reconnect')
            : 'Switch to ${current!.name}';
    final ctaDisabled = isActive && _s.control.state == LinkState.connected;
    final spectrum = current == null ? P.spectrumMac : P.spectrumFor(current.os.wire);

    return Stack(children: <Widget>[
        Positioned.fill(
          child: Opacity(
            opacity: q.clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.topCenter,
              transform: Matrix4.translationValues(0, (1 - q) * (MediaQuery.paddingOf(context).top + 8), 0)
                ..multiply(Matrix4.diagonal3Values(sx, sy, 1)),
              child: ClipRRect(
                borderRadius: BorderRadius.all(
                  Radius.elliptical(radius / math.max(sx, 0.01), radius / math.max(sy, 0.01)),
                ),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: const ColoredBox(color: Color(0x8C000000), child: SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Opacity(
            opacity: (qc * 1.3).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - qc) * -14),
              child: SafeArea(
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(children: <Widget>[
                    _head(hosts.length),
                    Expanded(child: _coverflow(hosts, active, size)),
                    _foot(n, idx, ctaLabel, ctaDisabled, spectrum),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]);
  }

  Widget _head(int paired) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            _cap('$paired paired · UDP ${Proto.port}'),
            const SizedBox(height: 6),
            Text('Computers', style: PT.display(40)),
          ]),
        ),
        Semantics(
          button: true,
          label: 'Close',
          child: GestureDetector(
            onTap: _close,
            child: SizedBox(
              width: 40,
              height: 40,
              child: PrismGlass(
                radius: 20,
                child: const Center(child: Icon(Icons.close_rounded, size: 18, color: P.text)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _coverflow(List<PairedHost> hosts, PairedHost? active, Size screen) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;
      _cw = math.min(w * 0.64, (h - 40) / 1.42).clamp(150.0, 260.0);
      final ch = _cw * 1.42;
      final pos = _pos;
      final n = hosts.length + 1;
      final order = List<int>.generate(n, (i) => i)
        ..sort((a, b) => (b - pos).abs().compareTo((a - pos).abs()));

      final cards = <Widget>[];
      for (final i in order) {
        final d = i - pos;
        final ad = d.abs();
        final sg = d.sign;
        final x = sg * (math.min(ad, 1.0) * _cw * 0.8 + math.max(0.0, ad - 1) * _cw * 0.36);
        final z = -math.min(ad, 2.6) * 150;
        final ry = -d.clamp(-1.3, 1.3) * 46 * math.pi / 180;
        final s = 1 - math.min(ad, 2.0) * 0.04;
        final opacity = ad > 2.4 ? math.max(0.0, 1 - (ad - 2.4) * 2) : 1.0;
        if (opacity <= 0) continue;
        final m = Matrix4.identity()
          ..setEntry(3, 2, 1 / 820)
          ..multiply(Matrix4.translationValues(x, 0, z))
          ..multiply(Matrix4.rotationY(ry))
          ..multiply(Matrix4.diagonal3Values(s, s, 1));
        final adc = math.min(1.0, ad);
        final sd = d.clamp(-1.0, 1.0);
        final Widget card = i < hosts.length
            ? _HostCard(
                host: hosts[i],
                width: _cw,
                height: ch,
                ad: adc,
                sd: sd,
                t: _t,
                status: _status(hosts[i], active),
                latency: _latency(hosts[i], active),
              )
            : _AddCard(width: _cw, height: ch, ad: adc);
        cards.add(Positioned(
          left: (w - _cw) / 2,
          top: h * 0.46 - ch / 2,
          width: _cw,
          height: ch,
          child: Opacity(
            opacity: opacity,
            child: Transform(
              alignment: Alignment.center,
              transform: m,
              child: GestureDetector(onTap: () => _tapCard(i), child: card),
            ),
          ),
        ));
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _dragStart,
        onHorizontalDragUpdate: _dragUpdate,
        onHorizontalDragEnd: _dragEnd,
        onHorizontalDragCancel: _dragCancel,
        child: ClipRect(child: Stack(clipBehavior: Clip.none, children: cards)),
      );
    });
  }

  String _status(PairedHost h, PairedHost? active) {
    if (h.id == active?.id) {
      return switch (_s.control.state) {
        LinkState.connected => 'Connected',
        LinkState.connecting => 'Connecting',
        LinkState.lost => 'Offline',
        LinkState.idle => 'Ready',
      };
    }
    final online = widget.isOnline;
    if (online == null) return 'Paired';
    return online(h.id) ? 'Ready' : 'Away';
  }

  int? _latency(PairedHost h, PairedHost? active) {
    if (h.id != active?.id) return null;
    return _s.control.isConnected ? _s.control.latencyMs : null;
  }

  Widget _foot(int n, int idx, String label, bool disabled, List<Color> spectrum) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          for (var i = 0; i < n; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == idx ? 6.25 : 5,
              height: i == idx ? 6.25 : 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == idx ? P.text : _alpha(P.text, 0.16),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          enabled: !disabled,
          label: label,
          child: GestureDetector(
            onTap: disabled ? null : () => _choose(idx),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: SizedBox(
                height: 50,
                child: PrismGlass(
                  radius: 25,
                  strong: true,
                  glow: disabled ? 0.35 : 0.9,
                  spectrum: spectrum,
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PT.body.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.15,
                        color: disabled ? P.text2 : P.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _cap('Flick the cards · three fingers on the pad switch too', align: TextAlign.center),
      ]),
    );
  }
}

// ----------------------------------------------------------------- cards

/// Iridescent card background derived from the host's spectrum.
Gradient _cardGradient(PairedHost h) {
  final c = P.spectrumFor(h.os.wire);
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  final hash = h.id.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xffff);
  final jitter = (hash % 100) / 100;
  if (h.os == HostOs.mac) {
    return RadialGradient(
      center: Alignment(-0.1 + jitter * 0.2, 0.04),
      radius: 0.95,
      colors: <Color>[
        Color.lerp(c[0], black, 0.88)!,
        Color.lerp(c[0], black, 0.25)!,
        c[0],
        c[1],
        Color.lerp(c[1], white, 0.6)!,
        Color.lerp(c[1], white, 0.9)!,
      ],
      stops: const <double>[0, 0.26, 0.44, 0.64, 0.86, 1],
    );
  }
  return LinearGradient(
    begin: Alignment(-0.2 - jitter * 0.2, -1),
    end: Alignment(0.2 + jitter * 0.2, 1),
    colors: <Color>[
      Color.lerp(c[0], black, 0.78)!,
      Color.lerp(c[0], black, 0.4)!,
      Color.lerp(c[1], c[0], 0.3)!,
      c[2],
      c[3],
    ],
    stops: const <double>[0, 0.24, 0.48, 0.7, 1],
  );
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.width,
    required this.height,
    required this.ad,
    required this.sd,
    required this.t,
    required this.status,
    required this.latency,
  });

  final PairedHost host;
  final double width;
  final double height;

  /// |distance| from centre (0..1) and signed distance (-1..1).
  final double ad;
  final double sd;
  final double t;
  final String status;
  final int? latency;

  @override
  Widget build(BuildContext context) {
    final g = _cardGradient(host);
    const rainbow = LinearGradient(colors: <Color>[
      Color(0xFFFF2D55),
      Color(0xFFFFB02E),
      Color(0xFFE8FF3D),
      Color(0xFF22E58B),
      Color(0xFF26CEFF),
      Color(0xFF3D6BFF),
      Color(0xFFA24DFF),
    ], stops: <double>[0, 0.2, 0.36, 0.52, 0.68, 0.84, 1]);
    const onCard = Color(0xFFFFFFFF);

    return Stack(clipBehavior: Clip.none, children: <Widget>[
      // Spectral smear spilling past the edges.
      Positioned(
        left: -width * 0.14,
        right: -width * 0.14,
        top: height * 0.02,
        bottom: height * 0.02,
        child: IgnorePointer(
          child: Opacity(
            opacity: (0.45 + ad * 0.5).clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(1 + ad * 0.25, 1, 1),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: g,
                    borderRadius: BorderRadius.circular(40),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      // Chromatic dispersion at the leading edge while off-centre.
      if (ad > 0.02)
        Positioned(
          left: width * (0.15 + sd * 0.4),
          width: width * 0.7,
          top: height * 0.06,
          bottom: height * 0.06,
          child: IgnorePointer(
            child: Opacity(
              opacity: (ad * 0.9).clamp(0.0, 1.0),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: rainbow,
                    borderRadius: BorderRadius.all(Radius.elliptical(width * 0.28, height * 0.35)),
                  ),
                ),
              ),
            ),
          ),
        ),
      // Face.
      Positioned.fill(
        child: Container(
          decoration: BoxDecoration(
            gradient: g,
            borderRadius: BorderRadius.circular(26),
            boxShadow: const <BoxShadow>[
              BoxShadow(color: Color(0xCC000000), blurRadius: 60, offset: Offset(0, 30), spreadRadius: -30),
            ],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0x38FFFFFF)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Stack(children: <Widget>[
              // Moving sheen band.
              Positioned(
                left: -width * 0.4,
                right: -width * 0.4,
                top: -height * 0.4,
                bottom: -height * 0.4,
                child: IgnorePointer(
                  child: Transform.translate(
                    offset: Offset(sd * -0.26 * width * 1.8, 0),
                    child: Opacity(
                      opacity: 0.55,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: const Alignment(-1, -0.27),
                            end: const Alignment(1, 0.27),
                            colors: const <Color>[
                              Color(0x00FFFFFF),
                              Color(0x47FFFFFF),
                              Color(0x1FBEE6FF),
                              Color(0x00FFFFFF),
                            ],
                            stops: const <double>[0.38, 0.47, 0.52, 0.6],
                            transform: GradientRotation(math.sin(t * 0.4) * 0.05),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: onCard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text(
                          host.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: PT.title.copyWith(
                            color: onCard,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.63,
                            height: 1.02,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${host.isMac ? 'macOS' : 'Windows'} · ${host.address}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PT.body.copyWith(color: _alpha(onCard, 0.72), fontSize: 12.5),
                        ),
                      ]),
                      Flexible(
                        child: Center(
                          child: FractionallySizedBox(
                            widthFactor: 0.84,
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: CustomPaint(
                                painter: _DialPainter(
                                  frac: (latency ?? 0) / 40,
                                  live: latency != null,
                                  label: PT.mono(7.5).copyWith(color: _alpha(onCard, 0.85)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: <Widget>[
                          _cap(status, color: _alpha(onCard, 0.8)),
                          const Spacer(),
                          Text(
                            latency == null ? '—' : '$latency ms',
                            style: PT.mono(15).copyWith(color: onCard, letterSpacing: -0.3),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({required this.width, required this.height, required this.ad});

  final double width;
  final double height;
  final double ad;

  @override
  Widget build(BuildContext context) {
    final spec = P.spectrumMac;
    return Stack(clipBehavior: Clip.none, children: <Widget>[
      Positioned(
        left: -width * 0.14,
        right: -width * 0.14,
        top: height * 0.02,
        bottom: height * 0.02,
        child: IgnorePointer(
          child: Opacity(
            opacity: (0.45 + ad * 0.5).clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, 0.2),
                  radius: 0.6,
                  colors: <Color>[_alpha(spec[1], 0.6), _alpha(spec[1], 0)],
                ),
              ),
            ),
          ),
        ),
      ),
      Positioned.fill(
        child: PrismGlass(
          radius: 26,
          strong: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 74,
                height: 74,
                child: CustomPaint(
                  painter: _AddRingPainter(spec),
                  child: const Center(child: Icon(Icons.add_rounded, size: 30, color: P.text)),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Add computer',
                style: PT.title.copyWith(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.57),
              ),
              const SizedBox(height: 12),
              _cap('Scan Wi-Fi or enter an IP', align: TextAlign.center),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _AddRingPainter extends CustomPainter {
  _AddRingPainter(this.spec);

  final List<Color> spec;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawCircle(
      rect.center,
      size.shortestSide / 2 - 0.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = SweepGradient(
          colors: <Color>[spec[0], spec[2], spec[3], spec[1], spec[0]],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_AddRingPainter old) => old.spec != spec;
}

/// The card's tick-ring dial: 48 ticks, a dark sphere, a latency wedge and
/// the four mode labels.
class _DialPainter extends CustomPainter {
  _DialPainter({required this.frac, required this.live, required this.label});

  final double frac;
  final bool live;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 200;
    canvas.save();
    canvas.scale(k, k);
    const c = Offset(100, 100);
    canvas.drawCircle(
      c,
      84,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = const Color(0x4DFFFFFF),
    );
    for (var i = 0; i < 48; i++) {
      final a = i / 48 * _tau - math.pi / 2;
      final major = i % 12 == 0;
      final r1 = major ? 86.5 : 88.0;
      final r2 = major ? 95.0 : 91.0;
      canvas.drawLine(
        c + Offset(math.cos(a) * r1, math.sin(a) * r1),
        c + Offset(math.cos(a) * r2, math.sin(a) * r2),
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = major ? 1.3 : 0.7
          ..color = Color.fromRGBO(255, 255, 255, major ? 0.95 : 0.45),
      );
    }
    final sphere = Rect.fromCircle(center: c, radius: 62);
    canvas.drawCircle(
      c,
      62,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.62 * 1.6,
          colors: <Color>[Color(0x8C0B0F33), Color(0xEB020208), Color(0xF5000000)],
          stops: <double>[0, 0.72, 1],
        ).createShader(sphere),
    );
    if (live) {
      final f = frac.clamp(0.02, 0.98);
      final path = Path()
        ..moveTo(100, 100)
        ..arcTo(sphere, -math.pi / 2, f * _tau, false)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0x00FFFFFF), Color(0xD9FFFFFF)],
          ).createShader(sphere),
      );
    }
    canvas.drawCircle(
      c,
      62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = const Color(0x2EFFFFFF),
    );
    const labels = <(String, double, double)>[
      ('TRACK', 100, 30),
      ('AIR', 171, 102.5),
      ('MEDIA', 100, 176),
      ('KEYS', 29, 102.5),
    ];
    for (final (text, x, y) in labels) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: label.copyWith(fontSize: 7.5, letterSpacing: 0.6)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height * 0.78));
      tp.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.frac != frac || old.live != live || old.label != label;
}
