// Raw multi-touch → trackpad semantics. Fed directly from Listener pointer
// events (not GestureDetector) so every finger is seen with zero arena delay.
//
// Gestures:
//   1 finger move ............ pointer move (accelerated)
//   tap / double / triple .... CLICK left count 1/2/3 (tap-to-click)
//   2-finger tap ............. right click
//   3-finger tap ............. middle click
//   2-finger drag ............ scroll, with inertia after lift
//   pinch .................... GESTURE zoom in / out
//   tap-and-hold, then move .. drag (left button held); lifting locks the
//                              drag, the next tap drops it
//   3-finger swipe L/R ....... switch host
//   3-finger swipe up/down ... GESTURE overview / show desktop
//   right-edge strip ......... vertical scroll
//
// Motion pipeline: pointer events only accumulate raw deltas; once per vsync
// (SchedulerBinding frame callback, 120 Hz on 120 Hz phones) the frame's
// total is run through the 1-euro-filtered velocity and the continuous
// acceleration curve and sent as ONE move / scroll. Nothing is dropped:
// discrete events (click, button) flush the pending delta first. Scroll
// inertia is a FrictionSimulation evaluated per frame with the real frame dt;
// the engine schedules its own frames, so callers no longer drive `tick`.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/physics.dart' show FrictionSimulation, Tolerance;
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../net/protocol.dart';
import 'trackpad_math.dart';

class TrackpadConfig {
  const TrackpadConfig({
    required this.pointerSpeed,
    required this.acceleration,
    required this.scrollSpeed,
    required this.naturalScroll,
    required this.tapToClick,
  });

  final double pointerSpeed;
  final double acceleration;
  final double scrollSpeed;
  final bool naturalScroll;
  final bool tapToClick;
}

enum TrackpadFeedback {
  tap,
  multiTap,
  rightClick,
  middleClick,
  dragStart,
  dragLocked,
  dragEnd,
  scrollStart,
  zoom,
  gesture,
  switchHost,
}

class TrackpadOutput {
  const TrackpadOutput({
    required this.move,
    required this.scroll,
    required this.click,
    required this.button,
    required this.gesture,
    required this.switchHost,
    required this.feedback,
  });

  final void Function(double dx, double dy) move;
  final void Function(double dx, double dy) scroll;
  final void Function(int button, int count) click;
  final void Function(int button, bool down) button;
  final void Function(int gestureId) gesture;

  /// +1 = next host (fingers swiped left), -1 = previous (swiped right).
  final void Function(int direction) switchHost;
  final void Function(TrackpadFeedback kind, Offset at) feedback;
}

enum _Mode { idle, one, two, three, settle }

enum _TwoKind { pending, scroll, pinch }

class _Finger {
  _Finger(this.start) : last = start;

  final Offset start;
  Offset last;
  bool moved = false; // beyond tap slop
  bool live = false; // past the dead zone, moving the cursor
  double pendingDx = 0;
  double pendingDy = 0;
}

/// Requests [callback] on the next vsync with the frame timestamp.
typedef FrameScheduler = void Function(
    void Function(Duration timeStamp) callback);

void _scheduleWithBinding(void Function(Duration) callback) {
  SchedulerBinding.instance.scheduleFrameCallback(callback);
}

class TrackpadEngine {
  TrackpadEngine({
    required this.output,
    required this.config,
    FrameScheduler? scheduleFrame,
  }) : _scheduleFrame = scheduleFrame ?? _scheduleWithBinding;

  final TrackpadOutput output;
  final TrackpadConfig Function() config;
  final FrameScheduler _scheduleFrame;

  static const double tapSlop = 10;
  static const int tapMaxUs = 260000;
  static const int multiTapUs = 320000;
  static const double multiTapSlop = 40;
  static const Duration holdDuration = Duration(milliseconds: 450);
  static const double deadZone = 1.5;
  static const double scrollStartTravel = 8;
  static const double pinchStartSpread = 36;
  static const double pinchStep = 1.32;
  static const double swipeDistance = 64;
  static const double stripGain = 1.6;
  static const double minInertiaSpeed = 140;
  static const double inertiaDrag = 0.12; // velocity left after 1 s
  static const double inertiaStopSpeed = 25;

  final Map<int, _Finger> _fingers = <int, _Finger>{};
  _Mode _mode = _Mode.idle;
  int _maxFingers = 0;
  int _gestureStartUs = 0;
  bool _anyMoved = false;

  _TwoKind _two = _TwoKind.pending;
  Offset _twoStartCentroid = Offset.zero;
  Offset _twoLastCentroid = Offset.zero;
  double _twoStartSpread = 0;
  double _pinchRef = 1;

  Offset _threeStart = Offset.zero;
  bool _threeFired = false;

  Timer? _holdTimer;
  bool _dragging = false;
  bool _dragLocked = false;

  int? _lastTapUs;
  Offset _lastTapPos = Offset.zero;
  int _tapCount = 0;

  final PointerAccelerator _accel = PointerAccelerator();
  final VelocityEstimator _scrollVel = VelocityEstimator();

  // Per-frame coalescing (raw finger deltas, before gain / mapping).
  double _rawMoveX = 0, _rawMoveY = 0;
  int _rawMoveUs = 0;
  bool _hasRawMove = false;
  double _rawScrollX = 0, _rawScrollY = 0;
  int _rawScrollUs = 0;
  bool _hasRawScroll = false;
  bool _frameScheduled = false;
  bool _disposed = false;
  Duration? _lastFrame;

  // Inertia: FrictionSimulation along the fling direction.
  FrictionSimulation? _inertia;
  double _inertiaT = 0;
  double _inertiaPos = 0;
  double _inertiaDirX = 0;
  double _inertiaDirY = 0;

  int? _stripPointer;
  double _stripLastY = 0;

  bool get isDragging => _dragging;
  bool get isDragLocked => _dragLocked;
  bool get isScrolling =>
      (_mode == _Mode.two && _two == _TwoKind.scroll) || _stripPointer != null;
  /// The engine drives its own frames now; kept for callers that start a
  /// Ticker when this is true (it never is, so there is no double stepping).
  bool get needsTick => false;

  /// True while scroll inertia is coasting.
  bool get isCoasting => _inertia != null;
  int get fingerCount => _fingers.length;

  // ---------------------------------------------------------- pointer API

  void pointerDown(int pointer, Offset pos, int tUs) {
    stopInertia();
    if (_fingers.isEmpty) {
      _maxFingers = 0;
      _anyMoved = false;
      _gestureStartUs = tUs;
      _two = _TwoKind.pending;
      _threeFired = false;
      _mode = _Mode.idle;
    }
    _fingers[pointer] = _Finger(pos);
    _maxFingers = math.max(_maxFingers, _fingers.length);
    final n = _fingers.length;
    if (_mode == _Mode.settle) {
      _cancelHold();
      return;
    }
    if (n == 1) {
      _mode = _Mode.one;
      _accel.reset();
      if (!_dragging) _armHold(pointer);
    } else if (n == 2) {
      _cancelHold();
      _mode = _Mode.two;
      _two = _TwoKind.pending;
      _twoStartCentroid = _centroid();
      _twoLastCentroid = _twoStartCentroid;
      _twoStartSpread = _spread();
      _scrollVel.reset();
    } else if (n == 3) {
      _cancelHold();
      _mode = _Mode.three;
      _threeStart = _centroid();
      _threeFired = false;
    } else {
      _cancelHold();
      _mode = _Mode.settle;
    }
  }

  void pointerMove(int pointer, Offset pos, int tUs) {
    final f = _fingers[pointer];
    if (f == null) return;
    final delta = pos - f.last;
    f.last = pos;
    if (!f.moved && (pos - f.start).distance > tapSlop) {
      f.moved = true;
      _anyMoved = true;
      _cancelHold();
    }
    switch (_mode) {
      case _Mode.one:
        _moveOne(f, delta, tUs);
      case _Mode.two:
        _moveTwo(tUs);
      case _Mode.three:
        _moveThree();
      case _Mode.idle:
      case _Mode.settle:
        break;
    }
  }

  void pointerUp(int pointer, Offset pos, int tUs) =>
      _end(pointer, pos, tUs, cancelled: false);

  void pointerCancel(int pointer, int tUs) =>
      _end(pointer, null, tUs, cancelled: true);

  // ------------------------------------------------------ edge scroll strip

  void stripDown(int pointer, Offset pos, int tUs) {
    stopInertia();
    _stripPointer = pointer;
    _stripLastY = pos.dy;
    _scrollVel.reset();
  }

  void stripMove(int pointer, Offset pos, int tUs) {
    if (pointer != _stripPointer) return;
    final dy = pos.dy - _stripLastY;
    _stripLastY = pos.dy;
    if (dy == 0) return;
    _queueScroll(0, dy * stripGain, tUs);
  }

  void stripUp(int pointer, int tUs, {bool cancelled = false}) {
    if (pointer != _stripPointer) return;
    _stripPointer = null;
    _flushPending();
    if (!cancelled) _startInertia(tUs);
  }

  // ------------------------------------------------------------- inertia

  /// Legacy external driver. The engine schedules its own vsync callbacks
  /// (motion coalescing and inertia), so this only reports whether inertia is
  /// still running.
  bool tick(Duration elapsed) => _inertia != null;

  void stopInertia() {
    _inertia = null;
  }

  /// Emits any coalesced motion now instead of at the next vsync.
  void flush() => _flushPending();

  /// Releases anything held (drag) and forgets all state. Call on host switch,
  /// when leaving the trackpad, or when the app goes to the background.
  void reset() {
    _cancelHold();
    stopInertia();
    _dropPending();
    if (_dragging) output.button(MouseButton.left, false);
    _dragging = false;
    _dragLocked = false;
    _fingers.clear();
    _mode = _Mode.idle;
    _stripPointer = null;
    _tapCount = 0;
    _lastTapUs = null;
  }

  void dispose() {
    reset();
    _disposed = true;
  }

  // ----------------------------------------------------------- internals

  void _moveOne(_Finger f, Offset delta, int tUs) {
    double dx, dy;
    if (!f.live) {
      f.pendingDx += delta.dx;
      f.pendingDy += delta.dy;
      final d = math.sqrt(f.pendingDx * f.pendingDx + f.pendingDy * f.pendingDy);
      if (d < deadZone) return;
      f.live = true;
      dx = f.pendingDx;
      dy = f.pendingDy;
    } else {
      dx = delta.dx;
      dy = delta.dy;
    }
    _rawMoveX += dx;
    _rawMoveY += dy;
    _rawMoveUs = tUs;
    _hasRawMove = true;
    _requestFrame();
  }

  void _queueScroll(double fingerDx, double fingerDy, int tUs) {
    _rawScrollX += fingerDx;
    _rawScrollY += fingerDy;
    _rawScrollUs = tUs;
    _hasRawScroll = true;
    _requestFrame();
  }

  void _requestFrame() {
    if (_frameScheduled || _disposed) return;
    _frameScheduled = true;
    _scheduleFrame(_onFrame);
  }

  void _onFrame(Duration timeStamp) {
    _frameScheduled = false;
    if (_disposed) return;
    final last = _lastFrame;
    var dt = last == null ? 1 / 120 : (timeStamp - last).inMicroseconds / 1e6;
    if (!(dt > 0)) dt = 1 / 120;
    if (dt > 1 / 30) dt = 1 / 30; // a stalled frame must not jump
    _lastFrame = timeStamp;
    _flushPending();
    _stepInertia(dt);
    if (_inertia != null) {
      _requestFrame();
    } else {
      _lastFrame = null;
    }
  }

  /// Converts this frame's accumulated raw deltas into ONE move / scroll.
  void _flushPending() {
    if (_hasRawMove) {
      final dx = _rawMoveX, dy = _rawMoveY;
      _rawMoveX = 0;
      _rawMoveY = 0;
      _hasRawMove = false;
      if (dx != 0 || dy != 0) {
        final cfg = config();
        final (ox, oy) = _accel.apply(
          dx,
          dy,
          _rawMoveUs,
          pointerSpeed: cfg.pointerSpeed,
          acceleration: cfg.acceleration,
        );
        output.move(ox, oy);
      }
    }
    if (_hasRawScroll) {
      final dx = _rawScrollX, dy = _rawScrollY;
      _rawScrollX = 0;
      _rawScrollY = 0;
      _hasRawScroll = false;
      final cfg = config();
      final (sx, sy) = ScrollMapping.map(
        dx,
        dy,
        scrollSpeed: cfg.scrollSpeed,
        natural: cfg.naturalScroll,
      );
      if (sx != 0 || sy != 0) {
        output.scroll(sx, sy);
        _scrollVel.add(sx, sy, _rawScrollUs);
      }
    }
  }

  void _dropPending() {
    _rawMoveX = 0;
    _rawMoveY = 0;
    _rawScrollX = 0;
    _rawScrollY = 0;
    _hasRawMove = false;
    _hasRawScroll = false;
  }

  void _stepInertia(double dt) {
    final sim = _inertia;
    if (sim == null) return;
    _inertiaT += dt;
    final x = sim.x(_inertiaT);
    final d = x - _inertiaPos;
    _inertiaPos = x;
    if (d != 0) output.scroll(_inertiaDirX * d, _inertiaDirY * d);
    if (sim.isDone(_inertiaT) || _inertiaT > 3.0) _inertia = null;
  }

  void _moveTwo(int tUs) {
    if (_fingers.length != 2) return;
    final c = _centroid();
    final spread = _spread();
    if (_two == _TwoKind.pending) {
      final travel = (c - _twoStartCentroid).distance;
      final spreadDelta = (spread - _twoStartSpread).abs();
      if (spreadDelta > pinchStartSpread && spreadDelta > travel * 1.4) {
        _two = _TwoKind.pinch;
        _pinchRef = math.max(spread, 1.0);
      } else if (travel > scrollStartTravel) {
        _two = _TwoKind.scroll;
        output.feedback(TrackpadFeedback.scrollStart, c);
      } else {
        return;
      }
    }
    if (_two == _TwoKind.scroll) {
      final d = c - _twoLastCentroid;
      _twoLastCentroid = c;
      if (d.dx == 0 && d.dy == 0) return;
      _queueScroll(d.dx, d.dy, tUs);
    } else if (_two == _TwoKind.pinch) {
      final r = spread / _pinchRef;
      if (r >= pinchStep) {
        _pinchRef = spread;
        output.gesture(GestureId.zoomIn);
        output.feedback(TrackpadFeedback.zoom, c);
      } else if (r <= 1 / pinchStep) {
        _pinchRef = math.max(spread, 1.0);
        output.gesture(GestureId.zoomOut);
        output.feedback(TrackpadFeedback.zoom, c);
      }
    }
  }

  void _moveThree() {
    if (_threeFired || _fingers.length != 3) return;
    final c = _centroid();
    final d = c - _threeStart;
    final ax = d.dx.abs(), ay = d.dy.abs();
    if (ax > swipeDistance && ax > ay * 1.3) {
      _threeFired = true;
      output.switchHost(d.dx < 0 ? 1 : -1);
      output.feedback(TrackpadFeedback.switchHost, c);
    } else if (ay > swipeDistance && ay > ax * 1.3) {
      _threeFired = true;
      output.gesture(d.dy < 0 ? GestureId.overview : GestureId.showDesktop);
      output.feedback(TrackpadFeedback.gesture, c);
    }
  }

  void _end(int pointer, Offset? pos, int tUs, {required bool cancelled}) {
    final f = _fingers[pointer];
    if (f == null) return;
    // Centroid including the lifting finger, for feedback placement.
    if (pos != null) f.last = pos;
    final where = _centroid();
    _fingers.remove(pointer);
    // Whatever moved this frame goes out before any click / fling decision.
    _flushPending();

    if (_fingers.isNotEmpty) {
      // N → fewer fingers. A scroll that loses a finger flings now; the
      // remaining finger(s) do nothing until everything lifts.
      if (_mode == _Mode.two && _two == _TwoKind.scroll && !cancelled) {
        _startInertia(tUs);
      }
      if (_mode != _Mode.one) _mode = _Mode.settle;
      return;
    }

    _cancelHold();
    final mode = _mode;
    _mode = _Mode.idle;
    if (cancelled) return;

    final tapLike =
        !_anyMoved && (tUs - _gestureStartUs) <= tapMaxUs && tUs >= _gestureStartUs;
    final cfg = config();

    if (_maxFingers == 1) {
      if (_dragging) {
        if (_dragLocked && tapLike) {
          _dragging = false;
          _dragLocked = false;
          output.button(MouseButton.left, false);
          output.feedback(TrackpadFeedback.dragEnd, where);
        } else if (!_dragLocked) {
          _dragLocked = true;
          output.feedback(TrackpadFeedback.dragLocked, where);
        }
        return;
      }
      if (tapLike && cfg.tapToClick) {
        final last = _lastTapUs;
        final quick = last != null && tUs - last <= multiTapUs;
        final near = (where - _lastTapPos).distance <= multiTapSlop;
        _tapCount = (quick && near && _tapCount < 3) ? _tapCount + 1 : 1;
        _lastTapUs = tUs;
        _lastTapPos = where;
        output.click(MouseButton.left, _tapCount);
        output.feedback(
          _tapCount == 1 ? TrackpadFeedback.tap : TrackpadFeedback.multiTap,
          where,
        );
      }
    } else if (_maxFingers == 2) {
      if (tapLike && _two == _TwoKind.pending && cfg.tapToClick) {
        _lastTapUs = null;
        output.click(MouseButton.right, 1);
        output.feedback(TrackpadFeedback.rightClick, where);
      } else if (mode == _Mode.two && _two == _TwoKind.scroll) {
        _startInertia(tUs);
      }
    } else if (_maxFingers == 3) {
      if (tapLike && !_threeFired && cfg.tapToClick) {
        _lastTapUs = null;
        output.click(MouseButton.middle, 1);
        output.feedback(TrackpadFeedback.middleClick, where);
      }
    }
  }

  void _startInertia(int tUs) {
    final (vx, vy) = _scrollVel.velocity(tUs);
    _scrollVel.reset();
    final speed = math.sqrt(vx * vx + vy * vy);
    if (speed < minInertiaSpeed) return;
    _inertia = FrictionSimulation(
      inertiaDrag,
      0,
      speed,
      tolerance: const Tolerance(velocity: inertiaStopSpeed),
    );
    _inertiaDirX = vx / speed;
    _inertiaDirY = vy / speed;
    _inertiaT = 0;
    _inertiaPos = 0;
    _lastFrame = null;
    _requestFrame();
  }

  void _armHold(int pointer) {
    _holdTimer?.cancel();
    _holdTimer = Timer(holdDuration, () {
      _holdTimer = null;
      final f = _fingers[pointer];
      if (f == null ||
          _fingers.length != 1 ||
          _mode != _Mode.one ||
          f.moved ||
          _dragging) {
        return;
      }
      _dragging = true;
      _dragLocked = false;
      _flushPending();
      output.button(MouseButton.left, true);
      output.feedback(TrackpadFeedback.dragStart, f.last);
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  Offset _centroid() {
    if (_fingers.isEmpty) return Offset.zero;
    var x = 0.0, y = 0.0;
    for (final f in _fingers.values) {
      x += f.last.dx;
      y += f.last.dy;
    }
    return Offset(x / _fingers.length, y / _fingers.length);
  }

  double _spread() {
    if (_fingers.length < 2) return 0;
    final it = _fingers.values.iterator..moveNext();
    final a = it.current.last;
    it.moveNext();
    final b = it.current.last;
    return (a - b).distance;
  }
}
