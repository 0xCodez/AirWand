// Trackpad (Prism `.tp`): the remote card on top and the full-bleed pad
// below it. Raw Listener pointer events feed the existing TrackpadEngine
// (gesture set from docs/DESIGN.md) which sends through ControlClient; the
// same output is mirrored into the RemoteModel for the mini preview.
//
// Light: every finger owns a SpringOffset that chases its raw position and
// an intensity spring; the smoothed lights (never raw positions) are pushed
// to the SpectralController each frame.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../input/trackpad_engine.dart';
import '../../net/control.dart';
import '../../net/hosts.dart';
import '../../net/protocol.dart';
import '../../state/scope.dart';
import '../components/remote_preview.dart';
import '../prism/prism.dart';

class TrackpadView extends StatefulWidget {
  const TrackpadView({
    super.key,
    required this.host,
    required this.hostIndex,
    required this.hostCount,
    required this.spectral,
    required this.model,
    required this.onSwitchHost,
  });

  final PairedHost host;
  final int hostIndex;
  final int hostCount;

  /// Owned by ControlScreen so host switches can sweep / retint it.
  final SpectralController spectral;
  final RemoteModel model;

  /// +1 next host, -1 previous (three-finger swipe or the card chevrons).
  final ValueChanged<int> onSwitchHost;

  @override
  State<TrackpadView> createState() => _TrackpadViewState();
}

class _FingerLight {
  _FingerLight(this.id, Offset at)
      : pos = SpringOffset(at, response: 0.09, damping: 0.86),
        intensity = SpringValue(0, response: 0.22, damping: 0.9) {
    intensity.target = 1;
  }

  final int id;
  final SpringOffset pos;
  final SpringValue intensity;
  bool live = true;
}

enum _Badge { none, dragging, locked }

class _TrackpadViewState extends State<TrackpadView>
    with SingleTickerProviderStateMixin {
  late AirWandServices _s;
  TrackpadEngine? _engine;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  Duration _elapsed = Duration.zero;

  final Map<int, _FingerLight> _lights = <int, _FingerLight>{};
  final SpringValue _stripY = SpringValue(0, response: 0.36, damping: 0.86);
  final ValueNotifier<double> _stripPos = ValueNotifier<double>(0);

  _Badge _badge = _Badge.none;
  bool _used = false;
  bool _cue = false;
  bool _stripOn = false;
  int? _lrDown;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.model.addListener(_onModel);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_engine != null) return;
    _s = AirWandScope.of(context);
    final control = _s.control;
    final m = widget.model;
    _engine = TrackpadEngine(
      config: () {
        final st = _s.settings;
        return TrackpadConfig(
          pointerSpeed: st.pointerSpeed,
          acceleration: st.acceleration,
          scrollSpeed: st.scrollSpeed,
          naturalScroll: st.naturalScroll,
          tapToClick: st.tapToClick,
        );
      },
      output: TrackpadOutput(
        move: (dx, dy) {
          control.move(dx, dy);
          m.move(dx, dy);
          if (_badge == _Badge.none) m.action('Moving');
        },
        scroll: (dx, dy) {
          control.scroll(dx, dy);
          m.scrollBy(dx, dy);
          m.action('Scrolling');
        },
        click: (button, count) {
          control.click(button, count);
          m.click(button, count);
        },
        button: (button, down) {
          control.button(button, down);
          m.button(button, down);
        },
        gesture: (id) {
          control.gesture(id);
          m.gesture(id, _gestureLabel(id));
          m.action(_gestureLabel(id));
        },
        switchHost: (dir) => widget.onSwitchHost(dir),
        feedback: _onFeedback,
      ),
    );
  }

  @override
  void didUpdateWidget(TrackpadView old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
    }
  }

  TrackpadEngine get _e => _engine!;

  String _gestureLabel(int id) {
    final mac = widget.host.isMac;
    switch (id) {
      case GestureId.overview:
        return mac ? 'Mission Control' : 'Task View';
      case GestureId.appSwitcher:
        return 'App switcher';
      case GestureId.showDesktop:
        return 'Show desktop';
      case GestureId.previousSpace:
        return 'Previous space';
      case GestureId.nextSpace:
        return 'Next space';
      case GestureId.back:
        return 'Back';
      case GestureId.forward:
        return 'Forward';
      case GestureId.zoomIn:
        return 'Zoom in';
      case GestureId.zoomOut:
        return 'Zoom out';
      default:
        return 'Gesture';
    }
  }

  void _onFeedback(TrackpadFeedback kind, Offset at) {
    final h = _s.haptics;
    final m = widget.model;
    final sp = widget.spectral;
    switch (kind) {
      case TrackpadFeedback.tap:
        h.selection();
        sp.ripple(at);
        m.action('Click');
      case TrackpadFeedback.multiTap:
        h.selection();
        sp.ripple(at);
        m.action('Double click');
      case TrackpadFeedback.rightClick:
        h.light();
        sp.ripple(at);
        m.action('Right click');
      case TrackpadFeedback.middleClick:
        h.light();
        sp.ripple(at);
        m.action('Middle click');
      case TrackpadFeedback.dragStart:
        h.medium();
        sp.ripple(at);
        m.action('Dragging');
        _setBadge(_Badge.dragging);
      case TrackpadFeedback.dragLocked:
        h.selection();
        m.action('Drag lock');
        _setBadge(_Badge.locked);
      case TrackpadFeedback.dragEnd:
        h.light();
        sp.ripple(at);
        m.action('Dropped');
        _setBadge(_Badge.none);
      case TrackpadFeedback.zoom:
        h.selection();
      case TrackpadFeedback.gesture:
        h.light();
        sp.ripple(at);
      case TrackpadFeedback.scrollStart:
        m.action('Scrolling');
      case TrackpadFeedback.switchHost:
        break;
    }
  }

  void _setBadge(_Badge b) {
    if (_badge != b && mounted) setState(() => _badge = b);
  }

  void _onModel() {
    _stripY.target = widget.model.scroll / RemoteModel.scrollRange;
    _wake();
  }

  // -------------------------------------------------------------- frames

  void _wake() {
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
    _elapsed += Duration(microseconds: (dt * 1e6).round());

    // Scroll inertia lives in the engine and needs a monotonic clock.
    final inertia = _e.needsTick && _e.tick(_elapsed);

    final out = <SpectralLight>[];
    final dead = <int>[];
    for (final l in _lights.values) {
      l.pos.step(dt);
      l.intensity.step(dt);
      if (!l.live && l.intensity.value < 0.01) {
        dead.add(l.id);
        continue;
      }
      final v = l.pos.velocity;
      final speed = v.distance;
      out.add(
        SpectralLight(
          id: l.id,
          pos: l.pos.value,
          radius: 54 + math.min(30.0, speed * 0.02),
          intensity: l.intensity.value.clamp(0.0, 1.2),
          velocity: v,
        ),
      );
    }
    for (final id in dead) {
      _lights.remove(id);
    }
    widget.spectral.setLights(out);

    _stripY.step(dt);
    _stripPos.value = _stripY.value;

    if (!inertia && _lights.isEmpty && _stripY.settled) _ticker.stop();
  }

  // ------------------------------------------------------------ pointers

  void _down(PointerDownEvent e) {
    _e.pointerDown(e.pointer, e.localPosition, e.timeStamp.inMicroseconds);
    _lights[e.pointer] = _FingerLight(e.pointer, e.localPosition);
    if (_e.isDragging && _badge == _Badge.locked) _setBadge(_Badge.dragging);
    if (!_used) setState(() => _used = true);
    _syncCue();
    _wake();
  }

  void _move(PointerMoveEvent e) {
    _e.pointerMove(e.pointer, e.localPosition, e.timeStamp.inMicroseconds);
    _lights[e.pointer]?.pos.target = e.localPosition;
    _wake();
  }

  void _lift(int pointer) {
    final l = _lights[pointer];
    if (l != null) {
      l.live = false;
      l.intensity.target = 0;
    }
    _syncBadge();
    _syncCue();
    _wake();
  }

  void _up(PointerUpEvent e) {
    _e.pointerUp(e.pointer, e.localPosition, e.timeStamp.inMicroseconds);
    _lift(e.pointer);
  }

  void _cancel(PointerCancelEvent e) {
    _e.pointerCancel(e.pointer, e.timeStamp.inMicroseconds);
    _lift(e.pointer);
  }

  void _syncCue() {
    final on = _e.fingerCount >= 3 && widget.hostCount > 1;
    if (on != _cue) setState(() => _cue = on);
  }

  /// A locked drag that was moved again and lifted emits no feedback event,
  /// so derive the badge from the engine once all fingers are up.
  void _syncBadge() {
    if (_e.fingerCount > 0) return;
    if (!_e.isDragging) {
      _setBadge(_Badge.none);
    } else if (_e.isDragLocked) {
      _setBadge(_Badge.locked);
    }
  }

  void _stripDown(PointerDownEvent e) {
    _e.stripDown(e.pointer, e.localPosition, e.timeStamp.inMicroseconds);
    setState(() => _stripOn = true);
  }

  void _stripMove(PointerMoveEvent e) {
    _e.stripMove(e.pointer, e.localPosition, e.timeStamp.inMicroseconds);
  }

  void _stripUp(PointerEvent e, {bool cancelled = false}) {
    _e.stripUp(e.pointer, e.timeStamp.inMicroseconds, cancelled: cancelled);
    setState(() => _stripOn = false);
    _wake();
  }

  void _lr(int button, bool down) {
    if (down) {
      if (_lrDown != null) return;
      _s.haptics.selection();
      setState(() => _lrDown = button);
    } else {
      if (_lrDown != button) return;
      setState(() => _lrDown = null);
    }
    _s.control.button(button, down);
    widget.model.button(button, down);
    widget.model.action(
      down ? (button == 0 ? 'Left down' : 'Right down') : (button == 0 ? 'Click' : 'Right click'),
    );
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    if (_lrDown != null) _s.control.button(_lrDown!, false);
    _engine?.dispose(); // releases a held drag
    _ticker.dispose();
    _stripPos.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final spec = P.spectrumForHost(widget.host);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          RemotePreview(
            model: widget.model,
            host: widget.host,
            index: widget.hostIndex,
            count: widget.hostCount,
            spectrum: spec,
            onStep: widget.onSwitchHost,
          ),
          const SizedBox(height: 10),
          Expanded(child: _pad()),
        ],
      ),
    );
  }

  Widget _pad() {
    const radius = BorderRadius.all(Radius.circular(30));
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0xB3000000),
            blurRadius: 60,
            offset: Offset(0, 30),
            spreadRadius: -36,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // Light + black glass veil.
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _cancel,
              child: SpectralField(controller: widget.spectral),
            ),

            // Hairline + top sheen (veil edge).
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.fromBorderSide(BorderSide(color: P.hair, width: 1)),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment(0, -0.7),
                    colors: <Color>[Color(0x14FFFFFF), Color(0x00FFFFFF)],
                  ),
                ),
              ),
            ),

            // Pad UI.
            IgnorePointer(child: _padUi()),

            // Right-edge scroll strip.
            Positioned(
              right: 0,
              top: 46,
              bottom: 62,
              width: 30,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _stripDown,
                onPointerMove: _stripMove,
                onPointerUp: (e) => _stripUp(e),
                onPointerCancel: (e) => _stripUp(e, cancelled: true),
                child: _strip(),
              ),
            ),

            // L / R click bar.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 52,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: P.hair, width: 1)),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(child: _lrButton(0, 'LEFT')),
                    Container(width: 1, color: P.hair),
                    Expanded(child: _lrButton(1, 'RIGHT')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _padUi() {
    final control = _s.control;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          top: 15,
          left: 18,
          child: Text('TRACKPAD', style: PT.mono(9).copyWith(color: P.text3)),
        ),
        Positioned(
          top: 15,
          right: 18,
          child: ListenableBuilder(
            listenable: control,
            builder: (context, _) {
              final String label;
              final Color color;
              switch (control.state) {
                case LinkState.connected:
                  label = 'UDP · 120 HZ';
                  color = P.text3;
                case LinkState.connecting:
                  label = 'CONNECTING';
                  color = P.warn;
                case LinkState.lost:
                  label = 'NO LINK';
                  color = P.bad;
                case LinkState.idle:
                  label = 'IDLE';
                  color = P.text3;
              }
              return Text(label, style: PT.mono(9).copyWith(color: color));
            },
          ),
        ),

        // First-use hint.
        Align(
          alignment: const Alignment(0, -0.12),
          child: AnimatedOpacity(
            opacity: _used ? 0 : 1,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: _used ? const Offset(0, 0.12) : Offset.zero,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Touch and move',
                    style: PT.display(20).copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.5,
                      color: P.text2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'TAP TO CLICK · TWO FINGERS SCROLL · THREE SWITCH',
                    textAlign: TextAlign.center,
                    style: PT.mono(8.5).copyWith(color: P.text3),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Three-finger swipe cue.
        AnimatedOpacity(
          opacity: _cue ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Icon(Icons.chevron_left_rounded, size: 30, color: P.text3),
                Icon(Icons.chevron_right_rounded, size: 30, color: P.text3),
              ],
            ),
          ),
        ),

        // Drag badge.
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: AnimatedOpacity(
              opacity: _badge == _Badge.none ? 0 : 1,
              duration: const Duration(milliseconds: 220),
              child: AnimatedSlide(
                offset: _badge == _Badge.none ? const Offset(0, -0.3) : Offset.zero,
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutBack,
                child: AnimatedScale(
                  scale: _badge == _Badge.none ? 0.9 : 1,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutBack,
                  child: PrismGlass(
                    radius: 999,
                    strong: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      height: 28,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            _badge == _Badge.locked
                                ? Icons.lock_outline_rounded
                                : Icons.open_with_rounded,
                            size: 12,
                            color: P.text,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _badge == _Badge.locked ? 'DRAG LOCK' : 'DRAGGING',
                            style: PT.mono(9).copyWith(color: P.text),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _strip() {
    return LayoutBuilder(
      builder: (context, c) => Stack(
        children: <Widget>[
          Positioned(
            right: 9,
            top: 0,
            bottom: 0,
            width: 1,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00FFFFFF), P.hair2, P.hair2, Color(0x00FFFFFF)],
                  stops: <double>[0, 0.18, 0.82, 1],
                ),
              ),
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: _stripPos,
            builder: (context, y, _) => Positioned(
              right: 7,
              width: 5,
              height: 34,
              top: (c.maxHeight - 34).clamp(0.0, double.infinity) * y.clamp(0.0, 1.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: _stripOn ? P.text : P.text3.fade(0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lrButton(int button, String label) {
    final down = _lrDown == button;
    return Semantics(
      button: true,
      label: button == 0 ? 'Left click' : 'Right click',
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _lr(button, true),
        onPointerUp: (_) => _lr(button, false),
        onPointerCancel: (_) => _lr(button, false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          color: down ? P.hair : const Color(0x00000000),
          alignment: Alignment.center,
          child: Text(
            label,
            style: PT.mono(9).copyWith(color: down ? P.text : P.text3),
          ),
        ),
      ),
    );
  }
}
