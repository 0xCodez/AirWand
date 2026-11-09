// Pairing sheet: black glass sheet with a living spectral glow, the big
// 6-digit code in Martian Mono (digits spring in, staggered), a travelling
// spectral "waiting" beam, and a drawn check on success.
// Port of b-prism.html "Pairing".

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:airwand/ui/prism/prism.dart';

import '../../net/discovery.dart';
import '../../net/hosts.dart';
import '../../net/pairing.dart';
import '../../net/protocol.dart';
import '../../state/identity.dart';
import '../../state/scope.dart';

Color _alpha(Color c, double o) => c.withAlpha((o.clamp(0.0, 1.0) * 255).round());

Widget _cap(String s, {Color? color, TextAlign? align}) => Text(
      s.toUpperCase(),
      textAlign: align,
      style: PT.cap.copyWith(color: color ?? P.text3),
    );

/// Where to pair: an address plus whatever discovery already knows.
class PairingTarget {
  const PairingTarget({
    required this.address,
    this.port = Proto.port,
    this.hostId,
    this.name,
    this.os,
  });

  /// Accepts a [PairingTarget], [DiscoveredHost] or [PairedHost] (re-pair).
  factory PairingTarget.from(Object host) {
    if (host is PairingTarget) return host;
    if (host is DiscoveredHost) {
      return PairingTarget(
        address: host.address,
        port: host.port,
        hostId: host.id,
        name: host.name,
        os: host.os,
      );
    }
    if (host is PairedHost) {
      return PairingTarget(
        address: host.address,
        port: host.port,
        hostId: host.id,
        name: host.name,
        os: host.os,
      );
    }
    throw ArgumentError.value(host, 'host', 'Unsupported pairing target');
  }

  final String address;
  final int port;
  final String? hostId;
  final String? name;
  final HostOs? os;
}

/// Opens the pairing sheet for [host] (a [PairingTarget], [DiscoveredHost]
/// or [PairedHost]). On success the host is saved to the [HostStore] and made
/// active; the future completes with it, or null if cancelled / failed.
Future<PairedHost?> showPairingSheet(
  BuildContext context,
  Object host, {
  Offset? origin,
}) {
  final target = PairingTarget.from(host);
  return Navigator.of(context).push<PairedHost>(
    PageRouteBuilder<PairedHost>(
      opaque: false,
      barrierColor: const Color(0x8C000000),
      transitionDuration: const Duration(milliseconds: 620),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (context, animation, secondary) => PairingSheet(target: target),
      transitionsBuilder: (context, animation, secondary, child) {
        final reduce = MediaQuery.disableAnimationsOf(context);
        if (reduce) return FadeTransition(opacity: animation, child: child);
        final curved = CurvedAnimation(
          parent: animation,
          curve: const _SpringCurve(0.84),
          reverseCurve: Curves.easeInCubic,
        );
        return AnimatedBuilder(
          animation: curved,
          builder: (context, child) => FractionalTranslation(
            translation: Offset(0, (1 - curved.value) * 1.05),
            child: child,
          ),
          child: child,
        );
      },
    ),
  );
}

/// Closed-form damped spring, normalised to settle by t = 1.
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

class PairingSheet extends StatefulWidget {
  const PairingSheet({super.key, required this.target});

  final PairingTarget target;

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet>
    with SingleTickerProviderStateMixin {
  AirWandServices? _s;
  PairingSession? _session;
  PairingPhase _phase = PairingPhase.connecting;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _t = 0;
  double _codeAge = -1;
  bool _reduce = false;
  Timer? _closeTimer;
  bool _saved = false;

  final SpringValue _glow = SpringValue(0.2, response: 0.6, damping: 0.8);
  final SpringValue _okMix = SpringValue(0, response: 0.46, damping: 0.86);
  final SpringValue _check = SpringValue(0, response: 0.55, damping: 0.95);
  final List<SpringValue> _digits = List<SpringValue>.generate(
    6,
    (_) => SpringValue(0, response: 0.5, damping: 0.72),
  );

  @override
  void initState() {
    super.initState();
    _glow.target = 0.6;
    _ticker = createTicker(_tick)..start();
    Haptic.light();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.disableAnimationsOf(context);
    if (_s == null) {
      _s = AirWandScope.of(context);
      _start();
    }
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    _ticker.dispose();
    _disposeSession();
    super.dispose();
  }

  void _disposeSession() {
    final old = _session;
    if (old == null) return;
    old.removeListener(_onSession);
    if (old.phase != PairingPhase.success) old.cancel();
    old.dispose();
    _session = null;
  }

  void _start() {
    final s = _s;
    if (s == null) return;
    _disposeSession();
    _codeAge = -1;
    for (final d in _digits) {
      d.snap(0);
    }
    _okMix.snap(0);
    _check.snap(0);
    _glow.target = 0.6;
    final session = PairingSession(
      address: widget.target.address,
      port: widget.target.port,
      expectedHostId: widget.target.hostId,
      deviceId: s.identity.deviceId,
      deviceName: s.settings.deviceName,
      platform: DeviceIdentity.platform,
    );
    _session = session;
    _phase = session.phase;
    session.addListener(_onSession);
    session.start();
  }

  Future<void> _onSession() async {
    final session = _session;
    if (session == null || !mounted) return;
    final phase = session.phase;
    if (phase == _phase && phase != PairingPhase.confirm) {
      setState(() {});
      return;
    }
    final was = _phase;
    _phase = phase;
    switch (phase) {
      case PairingPhase.connecting:
        break;
      case PairingPhase.confirm:
        if (was != PairingPhase.confirm) {
          _codeAge = 0;
          Haptic.light();
        }
      case PairingPhase.success:
        _okMix.target = 1;
        _check.target = 1;
        _glow.target = 1.2;
        Haptic.success();
        final host = session.result;
        if (host != null && !_saved) {
          _saved = true;
          await _s?.hosts.upsert(host);
        }
        _closeTimer?.cancel();
        _closeTimer = Timer(const Duration(milliseconds: 1300), () {
          if (mounted) Navigator.of(context).pop(host);
        });
      case PairingPhase.failed:
        _glow.target = 0.25;
        Haptic.error();
    }
    if (mounted) setState(() {});
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.1) dt = 1 / 60;
    _t += dt;
    if (_codeAge >= 0) {
      _codeAge += dt;
      for (var i = 0; i < 6; i++) {
        if (_codeAge * 1000 >= 120 + i * 55) {
          if (_reduce) {
            _digits[i].snap(1);
          } else {
            _digits[i].target = 1;
          }
        }
      }
    }
    for (final d in _digits) {
      d.step(dt);
    }
    _glow.step(dt);
    _okMix.step(dt);
    _check.step(dt);
    setState(() {});
  }

  void _cancel() {
    if (_phase == PairingPhase.success) return;
    Haptic.tick();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final os = session?.hostOs ?? widget.target.os ?? HostOs.mac;
    final name = session?.hostName ?? widget.target.name ?? widget.target.address;
    final spectrum = P.spectrumFor(os.wire);
    final word = os == HostOs.mac ? 'Mac' : 'PC';
    final glowBreath = 1 + 0.04 * math.sin(_t * 1.3);
    final glow = (_glow.value.clamp(0.0, 1.0) * (0.9 + 0.1 * glowBreath)).clamp(0.0, 1.0);

    return Stack(children: <Widget>[
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _cancel,
        ),
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.all(8),
          child: Material(
            type: MaterialType.transparency,
            child: PrismGlass(
              radius: 40,
              strong: true,
              glow: glow,
              glowAt: Alignment.topCenter,
              spectrum: spectrum,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Stack(clipBehavior: Clip.none, children: <Widget>[
                Positioned(
                  left: -40,
                  right: -40,
                  top: -56,
                  height: 110,
                  child: IgnorePointer(
                    child: Transform.translate(
                      offset: Offset(math.sin(_t * 0.6) * 6, 0),
                      child: Transform.scale(
                        scale: glowBreath * (0.9 + 0.25 * _glow.value.clamp(0.0, 1.2)),
                        child: Opacity(
                          opacity: _glow.value.clamp(0.0, 1.0) * 0.9,
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                            child: CustomPaint(painter: _GlowPainter(spectrum)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                  Container(
                    width: 38,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: _alpha(P.text, 0.16),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  _head(name, os),
                  SizedBox(height: 230, child: _body(name, word, spectrum)),
                  _actions(),
                ]),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _head(String name, HostOs os) {
    return Row(children: <Widget>[
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: P.hair, borderRadius: BorderRadius.circular(12)),
        child: Icon(
          os == HostOs.mac ? Icons.laptop_mac_rounded : Icons.desktop_windows_rounded,
          size: 18,
          color: P.text2,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: PT.title.copyWith(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.6),
            ),
            const SizedBox(height: 2),
            _cap('${os == HostOs.mac ? 'macOS' : 'Windows'} · ${widget.target.address}'),
          ],
        ),
      ),
    ]);
  }

  Widget _body(String name, String word, List<Color> spectrum) {
    final ok = _okMix.value;
    final session = _session;
    if (_phase == PairingPhase.failed) {
      return _failed(session?.error ?? 'Pairing failed.');
    }
    final code = session?.code;
    final waiting = Opacity(
      opacity: (1 - ok).clamp(0.0, 1.0),
      child: Transform.scale(
        scale: 1 + 0.04 * ok,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _cap(code == null ? 'Secure handshake' : 'Pairing code'),
            const SizedBox(height: 12),
            code == null ? _placeholderCode() : _code(code),
            const SizedBox(height: 12),
            Text(
              code == null ? 'Reaching ${widget.target.address}' : 'Confirm this code on your $word',
              style: PT.body.copyWith(fontSize: 15, color: P.text2),
            ),
            const SizedBox(height: 12),
            CustomPaint(
              size: const Size(180, 1),
              painter: _BeamPainter(t: _t, spectrum: spectrum),
            ),
            const SizedBox(height: 12),
            _cap(code == null ? 'X25519 · end-to-end encrypted' : 'Waiting for your $word'),
          ],
        ),
      ),
    );
    final success = Opacity(
      opacity: ok.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: 0.94 + 0.06 * ok,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            CustomPaint(
              size: const Size(76, 76),
              painter: _CheckPainter(_check.value.clamp(0.0, 1.0)),
            ),
            const SizedBox(height: 12),
            Text('Paired', style: PT.display(30)),
            const SizedBox(height: 12),
            _cap('$name · end-to-end encrypted', align: TextAlign.center),
          ],
        ),
      ),
    );
    return Stack(fit: StackFit.expand, children: <Widget>[
      if (ok < 0.999) waiting,
      if (ok > 0.001) success,
    ]);
  }

  TextStyle get _codeStyle => PT.mono(56).copyWith(
        color: P.text,
        fontWeight: FontWeight.w400,
        letterSpacing: -1.2,
        height: 1,
        fontFeatures: const <ui.FontFeature>[ui.FontFeature.tabularFigures()],
      );

  Widget _placeholderCode() {
    final a = 0.25 + 0.2 * (0.5 + 0.5 * math.sin(_t * 3));
    final style = _codeStyle.copyWith(color: _alpha(P.text, a));
    return FittedBox(
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Text('···', style: style),
        const SizedBox(width: 22),
        Text('···', style: style),
      ]),
    );
  }

  Widget _code(String code) {
    final digits = code.padRight(6).substring(0, 6).split('');
    Widget digit(int i) {
      final q = _digits[i].value;
      Widget d = Text(digits[i], style: _codeStyle);
      final blur = math.max(0.0, 1 - q) * 6;
      if (blur > 0.05) {
        d = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: d);
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Opacity(
          opacity: (q * 1.5).clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, (1 - q) * 18), child: d),
        ),
      );
    }

    return Semantics(
      label: 'Pairing code ${digits.join(' ')}',
      child: FittedBox(
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          for (var i = 0; i < 3; i++) digit(i),
          const SizedBox(width: 22),
          for (var i = 3; i < 6; i++) digit(i),
        ]),
      ),
    );
  }

  Widget _failed(String message) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _alpha(P.bad, 0.5)),
          ),
          child: const Icon(Icons.close_rounded, color: P.bad, size: 28),
        ),
        const SizedBox(height: 14),
        Text("Couldn't pair", style: PT.display(26)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: PT.body.copyWith(fontSize: 14, color: P.text2),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () {
            Haptic.light();
            setState(_start);
          },
          child: PrismGlass(
            radius: 23,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
            child: Text('Try again',
                style: PT.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }

  Widget _actions() {
    final hidden = _phase == PairingPhase.success;
    return SizedBox(
      height: 40,
      child: Center(
        child: AnimatedOpacity(
          opacity: hidden ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          child: IgnorePointer(
            ignoring: hidden,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _cancel,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  _phase == PairingPhase.failed ? 'Close' : 'Cancel',
                  style: PT.body.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three spectral ellipses, blurred by the parent.
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.spectrum);

  final List<Color> spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    final cols = <Color>[spectrum[0], spectrum[2 % spectrum.length], spectrum[3 % spectrum.length]];
    for (var i = 0; i < 3; i++) {
      final c = Offset(size.width * (0.25 + 0.25 * i), size.height / 2);
      final rect = Rect.fromCenter(center: c, width: size.width * 0.6, height: size.height * 1.2);
      canvas.drawOval(
        rect,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: <Color>[cols[i], _alpha(cols[i], 0)],
            stops: const <double>[0, 0.7],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.spectrum != spectrum;
}

/// The hairline "waiting" beam with a spectral comet travelling across.
class _BeamPainter extends CustomPainter {
  _BeamPainter({required this.t, required this.spectrum});

  final double t;
  final List<Color> spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & Size(size.width, math.max(1.0, size.height));
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(1)));
    canvas.drawRect(rect, Paint()..color = P.hair2);
    final p = const Cubic(0.45, 0, 0.2, 1).transform((t % 1.8) / 1.8);
    final w = size.width * 0.6;
    final x = -w + p * (w * 2.7);
    final seg = Rect.fromLTWH(x, 0, w, rect.height);
    canvas.drawRect(
      seg,
      Paint()
        ..shader = LinearGradient(colors: <Color>[
          _alpha(spectrum[0], 0),
          spectrum[0],
          spectrum[2 % spectrum.length],
          spectrum[3 % spectrum.length],
          _alpha(spectrum[3 % spectrum.length], 0),
        ]).createShader(seg),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.t != t || old.spectrum != spectrum;
}

/// Hairline circle with a check stroke drawn by [progress].
class _CheckPainter extends CustomPainter {
  _CheckPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 84;
    canvas.drawCircle(
      Offset(42 * s, 42 * s),
      40 * s,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = P.hair2,
    );
    if (progress <= 0) return;
    final path = Path()
      ..moveTo(26 * s, 43.5 * s)
      ..relativeLineTo(11 * s, 11 * s)
      ..relativeLineTo(21 * s, -24 * s);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = P.text;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * progress), paint);
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
