// Discovery ("Nearby"): black stage, ultra-thin rotating tick rings with a
// spectral wave, slowly breathing spectral light, glass orbs with spectral
// rims for every computer found, a list of rows and manual IP entry.
// Port of b-prism.html "Discovery".

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbit/ui/prism/prism.dart';

import '../../net/discovery.dart';
import '../../net/protocol.dart';
import '../../state/scope.dart';
import 'pairing_sheet.dart';

const double _tau = math.pi * 2;

Color _alpha(Color c, double o) => c.withAlpha((o.clamp(0.0, 1.0) * 255).round());

Widget _cap(String s, {Color? color, TextAlign? align}) => Text(
      s.toUpperCase(),
      textAlign: align,
      style: PT.cap.copyWith(color: color ?? P.text3),
    );

IconData osIcon(HostOs os) =>
    os == HostOs.mac ? Icons.laptop_mac_rounded : Icons.desktop_windows_rounded;

String osName(HostOs os) => os == HostOs.mac ? 'macOS' : 'Windows';

/// Parses "192.168.1.24", "192.168.1.24:47821", "[fe80::1]:47821", "pc.local".
(String, int) parseHostPort(String input) {
  var s = input.trim();
  var port = Proto.port;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end > 0) {
      final rest = s.substring(end + 1);
      if (rest.startsWith(':')) port = int.tryParse(rest.substring(1)) ?? port;
      return (s.substring(1, end), port);
    }
  }
  final colons = ':'.allMatches(s).length;
  if (colons == 1) {
    final i = s.indexOf(':');
    port = int.tryParse(s.substring(i + 1)) ?? port;
    s = s.substring(0, i);
  }
  return (s, port);
}

class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key, this.canClose = false});

  /// True when pushed from the control screen ("Add computer").
  final bool canClose;

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _Orb {
  _Orb({required this.ang, required this.r, required this.w, required this.ph})
      : scale = SpringValue(0, response: 0.55, damping: 0.62);

  double ang;
  final double r;
  final double w;
  final double ph;
  final SpringValue scale;
  bool leaving = false;
}

class _DiscoveryScreenState extends State<DiscoveryScreen>
    with SingleTickerProviderStateMixin {
  final HostDiscovery _discovery = HostDiscovery();
  final Map<String, _Orb> _orbs = <String, _Orb>{};
  final TextEditingController _ip = TextEditingController();
  final FocusNode _ipFocus = FocusNode();
  final SpringValue _enter = SpringValue(0, response: 0.5, damping: 0.9);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _t = 0;
  bool _reduce = false;
  bool _manualOpen = false;
  bool _pairing = false;
  bool _showTip = false;
  String? _manualError;
  Timer? _tipTimer;
  int _spawned = 0;

  @override
  void initState() {
    super.initState();
    _enter.target = 1;
    _discovery.addListener(_onDiscovery);
    _discovery.start();
    _ticker = createTicker(_tick)..start();
    _tipTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showTip = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _ticker.dispose();
    _discovery.removeListener(_onDiscovery);
    _discovery.dispose();
    _ip.dispose();
    _ipFocus.dispose();
    super.dispose();
  }

  void _onDiscovery() {
    if (!mounted) return;
    final ids = _discovery.hosts.map((h) => h.id).toSet();
    var added = false;
    for (final id in ids) {
      final existing = _orbs[id];
      if (existing != null) {
        if (existing.leaving) {
          existing.leaving = false;
          existing.scale.target = 1;
        }
        continue;
      }
      final i = _spawned++;
      const radii = <double>[0.8, 0.55, 0.8, 0.55, 1.02, 0.3];
      final orb = _Orb(
        ang: (i.isEven ? -2.3 : 0.7) + (i ~/ 2) * 1.9,
        r: radii[i % radii.length],
        w: 0.06 * (i.isEven ? 1 : -1),
        ph: i * 2.1,
      );
      if (_reduce) {
        orb.scale.snap(1);
      } else {
        orb.scale.target = 1;
      }
      _orbs[id] = orb;
      added = true;
    }
    for (final e in _orbs.entries) {
      if (!ids.contains(e.key)) {
        e.value.leaving = true;
        e.value.scale.target = 0;
      }
    }
    if (added) Haptic.tick();
    setState(() {});
  }

  void _tick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.1) dt = 1 / 60;
    _t += _reduce ? 0 : dt;
    _enter.step(dt);
    final gone = <String>[];
    for (final e in _orbs.entries) {
      final o = e.value;
      o.scale.step(dt);
      if (!_reduce) o.ang += dt * o.w;
      if (o.leaving && o.scale.value < 0.02 && o.scale.settled) gone.add(e.key);
    }
    gone.forEach(_orbs.remove);
    setState(() {});
  }

  // ------------------------------------------------------------- actions

  Future<void> _pair(PairingTarget target) async {
    if (_pairing) return;
    _pairing = true;
    Haptic.light();
    try {
      final host = await showPairingSheet(context, target);
      if (!mounted) return;
      if (host != null && widget.canClose) Navigator.of(context).pop(host);
    } finally {
      _pairing = false;
    }
  }

  Future<void> _pick(DiscoveredHost h) async {
    final s = OrbitScope.of(context);
    if (s.hosts.contains(h.id)) {
      Haptic.medium();
      await s.hosts.updateEndpoint(h.id, address: h.address, port: h.port);
      await s.hosts.setActive(h.id);
      if (!mounted) return;
      if (widget.canClose) Navigator.of(context).pop();
      return;
    }
    await _pair(PairingTarget(
      address: h.address,
      port: h.port,
      hostId: h.id,
      name: h.name,
      os: h.os,
    ));
  }

  void _toggleManual() {
    Haptic.tick();
    setState(() {
      _manualOpen = !_manualOpen;
      _manualError = null;
    });
    if (_manualOpen) {
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        if (mounted) _ipFocus.requestFocus();
      });
    } else {
      _ipFocus.unfocus();
    }
  }

  Future<void> _submitManual() async {
    final raw = _ip.text.trim();
    if (raw.isEmpty) {
      setState(() => _manualError = 'Enter an address like 192.168.1.24');
      return;
    }
    final (address, port) = parseHostPort(raw);
    if (address.isEmpty || port <= 0 || port > 65535) {
      setState(() => _manualError = 'Enter an address like 192.168.1.24');
      return;
    }
    setState(() => _manualError = null);
    _ipFocus.unfocus();
    await _pair(PairingTarget(address: address, port: port));
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final hosts = _discovery.hosts;
    final s = OrbitScope.of(context);
    final q = _enter.value.clamp(0.0, 1.0);
    final status = hosts.isEmpty
        ? 'Looking for computers on Wi-Fi'
        : '${hosts.length} found · still looking';
    final spectrum = hosts.isEmpty
        ? P.spectrumMac
        : P.spectrumFor(hosts.first.os.wire);

    return Scaffold(
      backgroundColor: P.bg,
      resizeToAvoidBottomInset: true,
      body: Opacity(
        opacity: (q * 1.4).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 1.04 - 0.04 * q,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
                    child: Text('Nearby', style: PT.display(40)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(children: <Widget>[
                      _Pulse(t: _t, color: hosts.isEmpty ? P.text3 : P.ok),
                      const SizedBox(width: 8),
                      _cap(status),
                    ]),
                  ),
                  Expanded(child: _radar(hosts, spectrum)),
                  _found(hosts, s),
                  const SizedBox(height: 6),
                  _cap(
                    _showTip && hosts.isEmpty
                        ? 'Same Wi-Fi? Open Orbit on the computer, or enter its IP'
                        : 'Install Orbit for Mac or Windows on the computer you want to control',
                    align: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return SizedBox(
      height: 44,
      child: Row(children: <Widget>[
        if (widget.canClose || Navigator.of(context).canPop())
          _TextBtn(
            onTap: () => Navigator.of(context).maybePop(),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              const Icon(Icons.chevron_left_rounded, size: 22, color: P.text),
              Text('Back', style: PT.body.copyWith(fontWeight: FontWeight.w600)),
            ]),
          ),
        const Spacer(),
        _cap('_orbit._tcp · UDP ${Proto.port}'),
      ]),
    );
  }

  Widget _radar(List<DiscoveredHost> hosts, List<Color> spectrum) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth + 32;
      final h = c.maxHeight;
      final cx = w / 2;
      final cy = h / 2;
      final big = math.min(w * 0.5, h * 0.5) - 6;
      final r = math.max(0.0, big);
      final children = <Widget>[
        Positioned.fill(
          child: CustomPaint(
            painter: _RadarPainter(t: _t, spectrum: spectrum, reduce: _reduce),
          ),
        ),
        Positioned(
          left: cx - 23,
          top: cy - 23,
          width: 46,
          height: 46,
          child: PrismGlass(
            radius: 23,
            child: const Center(
              child: Icon(Icons.smartphone_rounded, size: 20, color: P.text),
            ),
          ),
        ),
      ];
      for (final host in hosts) {
        final o = _orbs[host.id];
        if (o == null) continue;
        final rad = r * o.r;
        final bob = math.sin(_t * 1.1 + o.ph) * 3;
        final x = cx + math.cos(o.ang) * rad;
        final y = cy + math.sin(o.ang) * rad + bob;
        final sc = math.max(0.0, o.scale.value);
        children.add(Positioned(
          left: x - 60,
          top: y - 29,
          width: 120,
          child: Opacity(
            opacity: (sc * 2).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: sc,
              alignment: const Alignment(0, -0.55),
              child: _OrbView(
                host: host,
                rot: (_t * 40 + o.ph * 60) * math.pi / 180,
                onTap: () => _pick(host),
              ),
            ),
          ),
        ));
      }
      return OverflowBox(
        maxWidth: w,
        minWidth: w,
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(clipBehavior: Clip.none, children: children),
        ),
      );
    });
  }

  Widget _found(List<DiscoveredHost> hosts, OrbitServices s) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: _manualOpen ? 150 : 230),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: hosts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final h = hosts[i];
                return _RowIn(
                  key: ValueKey<String>(h.id),
                  child: _HostRow(
                    host: h,
                    paired: s.hosts.contains(h.id),
                    onTap: () => _pick(h),
                  ),
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _TextBtn(
              onTap: _toggleManual,
              child: Text(
                _manualOpen ? 'Hide manual entry' : 'Enter IP manually',
                style: PT.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            child: _manualOpen ? _manualForm() : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _manualForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PrismGlass(
          radius: 20,
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(children: <Widget>[
            Expanded(
              child: TextField(
                controller: _ip,
                focusNode: _ipFocus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _submitManual(),
                cursorColor: P.text,
                style: PT.mono(14).copyWith(color: P.text, letterSpacing: 0),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: '192.168.1.24',
                  hintStyle: PT.mono(14).copyWith(color: P.text3, letterSpacing: 0),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _submitManual,
              child: PrismGlass(
                strong: true,
                radius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                child: Text('Connect',
                    style: PT.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
        if (_manualError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: _cap(_manualError!, color: P.warn),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- pieces

class _TextBtn extends StatelessWidget {
  const _TextBtn({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: DefaultTextStyle.merge(style: const TextStyle(color: P.text), child: child),
      ),
    );
  }
}

class _Pulse extends StatelessWidget {
  const _Pulse({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final a = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 3));
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _alpha(color, a),
        boxShadow: <BoxShadow>[BoxShadow(color: _alpha(color, a * 0.6), blurRadius: 6)],
      ),
    );
  }
}

/// Rows slide in like the prototype's `rowIn`.
class _RowIn extends StatelessWidget {
  const _RowIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (context, q, child) => Opacity(
        opacity: q.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - q) * -6), child: child),
      ),
      child: child,
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({required this.host, required this.paired, required this.onTap});

  final DiscoveredHost host;
  final bool paired;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: PrismGlass(
        radius: 20,
        padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
        child: Row(children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: P.hair,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(osIcon(host.os), size: 18, color: P.text2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PT.body.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.15,
                  ),
                ),
                const SizedBox(height: 3),
                _cap('${osName(host.os)} · ${host.address}'),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: P.hair,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              paired ? 'Connect' : 'Pair',
              style: PT.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A glass orb with a rotating spectral rim and blurred spectral halo.
class _OrbView extends StatelessWidget {
  const _OrbView({required this.host, required this.rot, required this.onTap});

  final DiscoveredHost host;
  final double rot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final spec = P.spectrumFor(host.os.wire);
    final sweep = SweepGradient(
      colors: <Color>[spec[0], spec[2], spec[3], spec[1], spec[0]],
      transform: GradientRotation(rot),
    );
    return Semantics(
      button: true,
      label: 'Pair with ${host.name}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          SizedBox(
            width: 58,
            height: 58,
            child: Stack(clipBehavior: Clip.none, children: <Widget>[
              Positioned(
                left: -8,
                top: -8,
                right: -8,
                bottom: -8,
                child: Opacity(
                  opacity: 0.55,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(shape: BoxShape.circle, gradient: sweep),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: P.glassStrong,
                        gradient: RadialGradient(
                          center: Alignment(-0.3, -0.44),
                          radius: 0.6,
                          colors: <Color>[Color(0x0EFFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _alpha(P.glassStrong, 0.6),
                  ),
                ),
              ),
              Positioned.fill(child: CustomPaint(painter: _RimPainter(sweep))),
              Center(child: Icon(osIcon(host.os), size: 22, color: P.text)),
            ]),
          ),
          const SizedBox(height: 7),
          Text(
            host.name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: PT.cap.copyWith(color: P.text2),
          ),
        ]),
      ),
    );
  }
}

class _RimPainter extends CustomPainter {
  _RimPainter(this.gradient);

  final Gradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawCircle(
      rect.center,
      size.shortestSide / 2 - 0.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = gradient.createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) => old.gradient != gradient;
}

class _Ring {
  const _Ring(this.f, this.n, this.maj, this.dir, this.sp);

  final double f;
  final int n;
  final int maj;
  final double dir;
  final double sp;
}

const List<_Ring> _rings = <_Ring>[
  _Ring(0.3, 60, 5, 1, 0.05),
  _Ring(0.55, 96, 8, -1, 0.03),
  _Ring(0.8, 144, 12, 1, 0.018),
  _Ring(1.02, 180, 15, -1, 0.01),
];

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.t, required this.spectrum, required this.reduce});

  final double t;
  final List<Color> spectrum;
  final bool reduce;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final cx = w / 2;
    final cy = h / 2;
    final big = math.min(w * 0.5, h * 0.5) - 6;
    if (big <= 0) return;

    // Slow spectral breathing under everything.
    final br = 0.5 + 0.5 * math.sin(t * 1.55);
    for (var i = 0; i < 4; i++) {
      final a = t * 0.35 + i * _tau / 4;
      final r0 = big * 0.12 * (1 + 0.4 * math.sin(t * 0.7 + i));
      final center = Offset(cx + math.cos(a) * r0, cy + math.sin(a) * r0);
      final radius = big * (0.4 + 0.1 * br);
      final col = spectrum[i % spectrum.length];
      final alpha = 0.5 * (0.6 + 0.4 * br);
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: <Color>[
              _alpha(col, alpha),
              _alpha(col, alpha * 0.45),
              _alpha(col, 0),
            ],
            stops: const <double>[0, 0.45, 1],
          ).createShader(rect),
      );
    }

    // Ultra-thin tick rings with a travelling spectral wave.
    final wave = (t / 4.2) % 1;
    final center = Offset(cx, cy);
    for (var ri = 0; ri < _rings.length; ri++) {
      final rg = _rings[ri];
      final rad = big * rg.f;
      final rot = t * rg.sp * rg.dir;
      final d = rg.f - wave * 1.25;
      final prox = reduce ? 0.25 : math.exp(-(d * d) / 0.014);
      final path = Path();
      for (var k = 0; k < rg.n; k++) {
        final a = rot + k / rg.n * _tau;
        final len = k % rg.maj == 0 ? 7.0 : 3.5;
        final ca = math.cos(a);
        final sa = math.sin(a);
        path
          ..moveTo(cx + ca * rad, cy + sa * rad)
          ..lineTo(cx + ca * (rad + len), cy + sa * (rad + len));
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = _alpha(P.text, 0.13 + 0.08 * prox),
      );
      if (prox > 0.02) {
        final rect = Rect.fromCircle(center: center, radius: rad + 8);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..blendMode = BlendMode.plus
            ..shader = SweepGradient(
              colors: <Color>[
                for (final c in <Color>[...spectrum, spectrum.first])
                  _alpha(c, 0.85 * prox),
              ],
              transform: GradientRotation(rot * 3 + ri),
            ).createShader(rect),
        );
      }
      canvas.drawCircle(
        center,
        math.max(0.0, rad - 3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = _alpha(P.text, 0.05 + 0.07 * prox),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.t != t || old.spectrum != spectrum || old.reduce != reduce;
}
