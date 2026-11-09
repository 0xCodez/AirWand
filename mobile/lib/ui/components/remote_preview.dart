// The "remote" card above the trackpad (Prism prototype `.remote`): a tiny
// live picture of the computer's screen with a spring-smoothed glide cursor,
// plus a readout of the last action and the last packet sent.
//
// The host never streams its screen, so the picture is a model: every packet
// the trackpad sends is mirrored into [RemoteModel], which integrates a
// virtual cursor on a virtual display. The painted cursor glides toward it
// on a SpringOffset (never jumps).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../net/hosts.dart';
import '../prism/prism.dart';

/// Mirror of what the trackpad sends, in virtual host pixels.
class RemoteModel extends ChangeNotifier {
  final Map<String, Offset> _cursors = <String, Offset>{};
  String _hostId = '';
  Size display = const Size(1440, 900);

  Offset cursor = const Offset(820, 430);
  double scroll = 0;
  static const double scrollRange = 1600;

  String actionText = 'Ready';
  String packetName = 'PONG';
  String packetDetail = '0x0B';

  /// Monotonic counters the painter turns into one-shot effects.
  int clickSerial = 0;
  int lastClickButton = 0;
  int overviewSerial = 0;
  int zoomSerial = 0;
  bool zoomIn = true;
  bool selecting = false;
  Offset selectFrom = Offset.zero;

  /// 0..1 decaying packet activity (drives the pill glow / pad corner).
  double activity = 0;
  DateTime lastPacketAt = DateTime.fromMillisecondsSinceEpoch(0);

  void setHost(PairedHost host) {
    if (host.id == _hostId) return;
    if (_hostId.isNotEmpty) _cursors[_hostId] = cursor;
    _hostId = host.id;
    display = host.isMac ? const Size(1440, 900) : const Size(1920, 1080);
    cursor = _cursors[host.id] ??
        Offset(display.width * 0.57, display.height * 0.48);
    selecting = false;
    notifyListeners();
  }

  void _packet(String name, String detail) {
    packetName = name;
    packetDetail = detail;
    lastPacketAt = DateTime.now();
    activity = math.min(1.0, activity + 0.06);
  }

  void action(String text) {
    if (text == actionText) return;
    actionText = text;
    notifyListeners();
  }

  static String _sgn(double v) {
    final r = v.round();
    return r >= 0 ? '+$r' : '$r';
  }

  void move(double dx, double dy) {
    cursor = Offset(
      (cursor.dx + dx).clamp(0, display.width - 1).toDouble(),
      (cursor.dy + dy).clamp(0, display.height - 1).toDouble(),
    );
    _packet('MOVE', '0x01 · dx ${_sgn(dx)}  dy ${_sgn(dy)}');
    notifyListeners();
  }

  void scrollBy(double dx, double dy) {
    scroll = (scroll + dy).clamp(0, scrollRange).toDouble();
    _packet('SCROLL', '0x04 · dx ${_sgn(dx)}  dy ${_sgn(dy)}');
    notifyListeners();
  }

  void click(int button, int count) {
    clickSerial++;
    lastClickButton = button;
    _packet('CLICK', '0x03 · button $button · count $count');
    notifyListeners();
  }

  void button(int button, bool down) {
    if (button == 0) {
      selecting = down;
      selectFrom = cursor;
    }
    _packet('BUTTON', '0x02 · button $button · ${down ? 'down' : 'up'}');
    notifyListeners();
  }

  void gesture(int id, String label) {
    if (id == 1) overviewSerial++;
    if (id == 8 || id == 9) {
      zoomSerial++;
      zoomIn = id == 8;
    }
    _packet('GESTURE', '0x05 · id $id · $label');
    notifyListeners();
  }

  void hello() {
    final session = math.Random().nextInt(0x7fffffff).toRadixString(16);
    _packet('HELLO', 'UDP · session ${session.padLeft(8, '0')} · seq 1');
    activity = 1;
    notifyListeners();
  }

  void pong(int? ms) {
    if (DateTime.now().difference(lastPacketAt).inMilliseconds < 1400) return;
    final d = ms == null ? '0x0B · waiting' : '0x0B · $ms ms';
    if (packetName == 'PONG' && packetDetail == d) return;
    packetName = 'PONG';
    packetDetail = d;
    notifyListeners();
  }
}

/// The glass remote card: mini screen + readout + host index chevrons.
class RemotePreview extends StatelessWidget {
  const RemotePreview({
    super.key,
    required this.model,
    required this.host,
    required this.index,
    required this.count,
    required this.spectrum,
    required this.onStep,
  });

  final RemoteModel model;
  final PairedHost host;
  final int index;
  final int count;
  final List<Color> spectrum;
  final ValueChanged<int> onStep;

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final res = host.isMac ? '1440×900' : '1920×1080';
    return PrismGlass(
      radius: 22,
      padding: const EdgeInsets.all(9),
      child: SizedBox(
        height: 89,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 142,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: P.hair2, width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: ColoredBox(
                    color: Colors.black,
                    child: _MiniScreen(
                      model: model,
                      isMac: host.isMac,
                      spectrum: spectrum,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 2, 1),
                child: ListenableBuilder(
                  listenable: model,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${host.isMac ? 'MACOS' : 'WINDOWS'} · $res',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PT.mono(9).copyWith(color: P.text2),
                            ),
                          ),
                          _NavButton(
                            icon: Icons.chevron_left_rounded,
                            label: 'Previous computer',
                            onTap: () => onStep(-1),
                          ),
                          Text(
                            '${_two(index + 1)}/${_two(count)}',
                            style: PT.mono(9).copyWith(color: P.text2),
                          ),
                          _NavButton(
                            icon: Icons.chevron_right_rounded,
                            label: 'Next computer',
                            onTap: () => onStep(1),
                          ),
                        ],
                      ),
                      _ActionText(text: model.actionText),
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: '${model.packetName} ',
                              style: const TextStyle(color: P.text),
                            ),
                            TextSpan(text: model.packetDetail),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PT.mono(9).copyWith(color: P.text2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 22,
          height: 22,
          child: Icon(icon, size: 15, color: P.text2),
        ),
      ),
    );
  }
}

/// Big readout line; each new text rises 6 px on a spring.
class _ActionText extends StatelessWidget {
  const _ActionText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[if (current != null) current],
      ),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: Tween<double>(begin: 0.35, end: 1).animate(a),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(a),
          child: child,
        ),
      ),
      child: Text(
        text,
        key: ValueKey<String>(text),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: PT.display(23).copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.69,
          height: 1,
          color: P.text,
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ mini screen

class _Click {
  _Click(this.at, this.button) : r = SpringValue(0, response: 0.42, damping: 0.9) {
    r.target = 1;
  }

  final Offset at;
  final int button;
  final SpringValue r;
  double age = 0;
}

class _MiniScreen extends StatefulWidget {
  const _MiniScreen({
    required this.model,
    required this.isMac,
    required this.spectrum,
  });

  final RemoteModel model;
  final bool isMac;
  final List<Color> spectrum;

  @override
  State<_MiniScreen> createState() => _MiniScreenState();
}

class _MiniScreenState extends State<_MiniScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  final SpringOffset _cursor =
      SpringOffset(const Offset(820, 430), response: 0.17, damping: 0.9);
  final SpringValue _press = SpringValue(1, response: 0.26, damping: 0.55);
  final SpringValue _overview = SpringValue(0, response: 0.6, damping: 0.86);
  final SpringValue _zoom = SpringValue(1, response: 0.5, damping: 0.75);
  final List<_Click> _clicks = <_Click>[];
  _Click? _menu;
  Offset _zoomAt = Offset.zero;
  double _overviewHold = 0;
  double _zoomHold = 0;

  int _clickSeen = 0;
  int _overviewSeen = 0;
  int _zoomSeen = 0;
  bool _wasSelecting = false;
  bool _reduce = false;

  final _MiniRepaint _repaint = _MiniRepaint();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    final m = widget.model;
    _cursor.snap(m.cursor);
    _clickSeen = m.clickSerial;
    _overviewSeen = m.overviewSerial;
    _zoomSeen = m.zoomSerial;
    m.addListener(_onModel);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void didUpdateWidget(_MiniScreen old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
    }
    if (old.isMac != widget.isMac) _cursor.snap(widget.model.cursor);
    _repaint.bump();
  }

  void _onModel() {
    final m = widget.model;
    _cursor.target = m.cursor;
    if (_reduce) _cursor.snap(m.cursor);
    if (m.clickSerial != _clickSeen) {
      _clickSeen = m.clickSerial;
      _clicks.add(_Click(m.cursor, m.lastClickButton));
      _press.value = 0.8;
      _press.target = 1;
      if (m.lastClickButton == 1) {
        _menu = _Click(m.cursor, 1);
      } else {
        _menu = null;
      }
    }
    if (m.overviewSerial != _overviewSeen) {
      _overviewSeen = m.overviewSerial;
      _overview.target = 1;
      _overviewHold = 1.1;
    }
    if (m.zoomSerial != _zoomSeen) {
      _zoomSeen = m.zoomSerial;
      _zoomAt = m.cursor;
      _zoom.target = m.zoomIn ? 1.4 : 0.78;
      _zoomHold = 0.52;
    }
    if (m.selecting != _wasSelecting) {
      _wasSelecting = m.selecting;
      _press.target = m.selecting ? 0.84 : 1;
    }
    _wake();
  }

  void _wake() {
    _repaint.bump();
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    final m = widget.model;
    m.activity *= math.exp(-dt * 1.6);

    if (_overviewHold > 0) {
      _overviewHold -= dt;
      if (_overviewHold <= 0) _overview.target = 0;
    }
    if (_zoomHold > 0) {
      _zoomHold -= dt;
      if (_zoomHold <= 0) _zoom.target = 1;
    }
    _cursor.step(dt);
    _press.step(dt);
    _overview.step(dt);
    _zoom.step(dt);
    for (final c in _clicks) {
      c.r.step(dt);
      c.age += dt;
    }
    _clicks.removeWhere((c) => c.age >= 0.75);
    final menu = _menu;
    if (menu != null) {
      menu.age += dt;
      if (menu.age > 1.5) menu.r.target = 0;
      menu.r.step(dt);
      if (menu.age > 2.3) _menu = null;
    }
    _repaint.bump();
    final busy = !_cursor.settled ||
        !_press.settled ||
        !_overview.settled ||
        !_zoom.settled ||
        _clicks.isNotEmpty ||
        _menu != null ||
        _overviewHold > 0 ||
        _zoomHold > 0;
    if (!busy) _ticker.stop();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MiniPainter(state: this, repaint: _repaint),
      size: Size.infinite,
    );
  }
}

class _MiniRepaint extends ChangeNotifier {
  void bump() => notifyListeners();
}

class _MiniPainter extends CustomPainter {
  _MiniPainter({required this.state, required Listenable repaint})
      : super(repaint: repaint);

  final _MiniScreenState state;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  void _blob(Canvas c, Offset at, double r, Color color, double alpha) {
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: <Color>[
          color.fade(alpha),
          color.fade(alpha * 0.35),
          color.fade(0),
        ],
        stops: const <double>[0, 0.45, 1],
      ).createShader(Rect.fromCircle(center: at, radius: r));
    c.drawCircle(at, r, paint);
  }

  void _window(Canvas c, Rect r, bool main, bool isMac, List<Color> spec) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(isMac ? 3 : 1.5));
    c.drawRRect(
      rr.shift(const Offset(0, 1.5)),
      Paint()..color = Colors.black.fade(0.35),
    );
    c.drawRRect(
      rr,
      Paint()..color = (main ? const Color(0xF0101016) : const Color(0xD80C0C10)),
    );
    final bar = r.height * 0.13;
    c.save();
    c.clipRRect(rr);
    c.drawRect(
      Rect.fromLTWH(r.left, r.top, r.width, bar),
      Paint()..color = Colors.white.fade(main ? 0.08 : 0.05),
    );
    if (isMac) {
      const lights = <Color>[Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)];
      for (var i = 0; i < 3; i++) {
        c.drawCircle(
          Offset(r.left + bar * 0.6 + i * bar * 0.55, r.top + bar / 2),
          bar * 0.17,
          Paint()..color = lights[i].fade(main ? 0.95 : 0.5),
        );
      }
    }
    final body = Rect.fromLTWH(r.left, r.top + bar, r.width, r.height - bar);
    final lines = Paint()..color = Colors.white.fade(main ? 0.12 : 0.07);
    for (var i = 0; i < 4; i++) {
      final y = body.top + body.height * (0.18 + i * 0.18);
      final w = body.width * (i.isEven ? 0.62 : 0.44);
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(body.left + body.width * 0.08, y, w, body.height * 0.06),
          const Radius.circular(1),
        ),
        lines,
      );
    }
    if (main) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            body.left + body.width * 0.08,
            body.bottom - body.height * 0.2,
            body.width * 0.24,
            body.height * 0.1,
          ),
          const Radius.circular(1.5),
        ),
        Paint()..color = spec[0].fade(0.9),
      );
    }
    c.restore();
    c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = Colors.white.fade(0.14),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = state;
    final m = s.widget.model;
    final spec = s.widget.spectrum;
    final isMac = s.widget.isMac;
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final sx = w / m.display.width, sy = h / m.display.height;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final zoom = s._zoom.value;
    if ((zoom - 1).abs() > 0.002) {
      final z = Offset(s._zoomAt.dx * sx, s._zoomAt.dy * sy);
      canvas.translate(z.dx, z.dy);
      canvas.scale(zoom, zoom);
      canvas.translate(-z.dx, -z.dy);
    }

    // Wallpaper: four spectral blobs on near-black.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = isMac ? const Color(0xFF05061A) : const Color(0xFF020A10),
    );
    final pos = isMac
        ? const <Offset>[Offset(0.25, 0.75), Offset(0.7, 0.35), Offset(0.55, 0.95), Offset(0.9, 0.85)]
        : const <Offset>[Offset(0.2, 0.3), Offset(0.65, 0.7), Offset(0.95, 0.2), Offset(0.4, 0.95)];
    for (var i = 0; i < 4 && i < spec.length; i++) {
      _blob(canvas, Offset(pos[i].dx * w, pos[i].dy * h), w * 0.55, spec[i], 0.75);
    }

    // Windows (fan out to an overview grid on GESTURE overview).
    final ov = s._overview.value.clamp(0.0, 1.1);
    final wins = isMac
        ? const <List<double>>[[0.07, 0.14, 0.5, 0.56], [0.3, 0.2, 0.6, 0.62]]
        : const <List<double>>[[0.05, 0.08, 0.48, 0.58], [0.33, 0.14, 0.6, 0.66]];
    for (var i = 0; i < wins.length; i++) {
      var x = wins[i][0] * w, y = wins[i][1] * h;
      var ww = wins[i][2] * w, hh = wins[i][3] * h;
      if (ov > 0.001) {
        final k = 1 - 0.4 * ov;
        final tx = (i == 1 ? 0.72 : 0.27) * w, ty = 0.47 * h;
        x = _lerp(x, tx - ww * k / 2, ov);
        y = _lerp(y, ty - hh * k / 2, ov);
        ww *= _lerp(1, k, ov);
        hh *= _lerp(1, k, ov);
      }
      _window(canvas, Rect.fromLTWH(x, y, ww, hh), i == 1, isMac, spec);
    }

    // Menu bar + dock (Mac) or taskbar (Windows).
    if (isMac) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, math.max(4.0, h * 0.05)),
        Paint()..color = Colors.black.fade(0.35),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.3, h * 0.88, w * 0.4, h * 0.085),
          const Radius.circular(3),
        ),
        Paint()..color = Colors.white.fade(0.14),
      );
      for (var i = 0; i < 6; i++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.318 + i * w * 0.063, h * 0.897, w * 0.043, h * 0.065),
            const Radius.circular(1.6),
          ),
          Paint()..color = spec[i % spec.length].fade(0.95),
        );
      }
    } else {
      canvas.drawRect(
        Rect.fromLTWH(0, h * 0.92, w, h * 0.08),
        Paint()..color = const Color(0xD9060810),
      );
      for (var i = 0; i < 5; i++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.39 + i * w * 0.046, h * 0.937, w * 0.03, h * 0.046),
            const Radius.circular(1),
          ),
          Paint()..color = i == 0 ? spec[0] : Colors.white.fade(0.55),
        );
      }
    }

    // Drag selection rectangle.
    if (m.selecting) {
      final a = Offset(m.selectFrom.dx * sx, m.selectFrom.dy * sy);
      final b = Offset(s._cursor.value.dx * sx, s._cursor.value.dy * sy);
      final r = Rect.fromPoints(a, b);
      canvas.drawRect(r, Paint()..color = spec[0].fade(0.22));
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = spec[spec.length - 1].fade(0.9),
      );
    }

    // Right-click context menu.
    final menu = s._menu;
    if (menu != null) {
      final a = menu.r.value.clamp(0.0, 1.0);
      final k = 0.92 + 0.08 * menu.r.value;
      final mw = w * 0.26, mh = h * 0.36;
      var mx = menu.at.dx * sx + 2, my = menu.at.dy * sy + 2;
      if (mx + mw > w) mx -= mw + 4;
      if (my + mh > h) my -= mh + 4;
      canvas.save();
      canvas.translate(mx, my);
      canvas.scale(k, k);
      final rr = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, mw, mh), const Radius.circular(2.5));
      canvas.drawRRect(rr, Paint()..color = const Color(0xFF16161C).fade(0.94 * a));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = Colors.white.fade(0.18 * a),
      );
      for (var i = 0; i < 5; i++) {
        final y = mh * (0.12 + i * 0.17);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(mw * 0.12, y, mw * (i == 1 ? 0.5 : 0.7), mh * 0.07),
            const Radius.circular(1),
          ),
          Paint()
            ..color = (i == 0 ? spec[0] : Colors.white).fade((i == 0 ? 0.9 : 0.4) * a),
        );
      }
      canvas.restore();
    }

    // Click ripples.
    for (final c in s._clicks) {
      final life = (1 - c.age / 0.75).clamp(0.0, 1.0);
      final at = Offset(c.at.dx * sx, c.at.dy * sy);
      final color = c.button == 1 ? spec[2 % spec.length] : spec[spec.length - 1];
      canvas.drawCircle(
        at,
        2 + 9 * c.r.value,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.fade(0.9 * life),
      );
    }

    // Glide cursor (arrow), squashed on press.
    final cur = Offset(s._cursor.value.dx * sx, s._cursor.value.dy * sy);
    final k = s._press.value.clamp(0.6, 1.3);
    canvas.save();
    canvas.translate(cur.dx, cur.dy);
    canvas.scale(k, k);
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 9.5)
      ..lineTo(2.4, 7.4)
      ..lineTo(4.1, 11)
      ..lineTo(5.6, 10.3)
      ..lineTo(4, 6.8)
      ..lineTo(7.2, 6.8)
      ..close();
    canvas.drawPath(
      arrow.shift(const Offset(0.4, 0.8)),
      Paint()..color = Colors.black.fade(0.45),
    );
    canvas.drawPath(arrow, Paint()..color = Colors.white);
    canvas.drawPath(
      arrow,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black,
    );
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MiniPainter old) => old.state != state;
}
