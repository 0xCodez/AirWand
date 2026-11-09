import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:airwand/input/trackpad_engine.dart';
import 'package:airwand/input/trackpad_math.dart';
import 'package:airwand/net/protocol.dart';

void main() {
  group('AccelerationCurve', () {
    test('acceleration 0 is perfectly linear', () {
      for (final v in <double>[0, 10, 100, 500, 1000, 3000, 10000]) {
        expect(
          AccelerationCurve.gain(v, pointerSpeed: 1.5, acceleration: 0),
          closeTo(1.5, 1e-12),
        );
      }
    });

    test('is monotonic non-decreasing in speed', () {
      for (final a in <double>[0.2, 0.6, 1.0]) {
        var last = 0.0;
        for (var v = 0.0; v <= 4000; v += 25) {
          final g = AccelerationCurve.gain(v, pointerSpeed: 1, acceleration: a);
          expect(g, greaterThanOrEqualTo(last - 1e-12));
          last = g;
        }
      }
    });

    test('is bounded by min/max gain and hits both ends', () {
      const s = 1.2, a = 0.6;
      final lo = AccelerationCurve.minGain(pointerSpeed: s, acceleration: a);
      final hi = AccelerationCurve.maxGain(pointerSpeed: s, acceleration: a);
      expect(
        AccelerationCurve.gain(0, pointerSpeed: s, acceleration: a),
        closeTo(lo, 1e-12),
      );
      expect(
        AccelerationCurve.gain(AccelerationCurve.halfSpeed,
            pointerSpeed: s, acceleration: a),
        closeTo((lo + hi) / 2, 1e-9),
      );
      expect(
        AccelerationCurve.gain(1e6, pointerSpeed: s, acceleration: a),
        closeTo(hi, 1e-3),
      );
      expect(lo, lessThan(s));
      expect(hi, greaterThan(s));
    });

    test('scales linearly with pointer speed', () {
      final g1 = AccelerationCurve.gain(700, pointerSpeed: 1, acceleration: 0.5);
      final g2 = AccelerationCurve.gain(700, pointerSpeed: 2, acceleration: 0.5);
      expect(g2, closeTo(2 * g1, 1e-12));
    });

    test('handles garbage input', () {
      final g = AccelerationCurve.gain(
        double.nan,
        pointerSpeed: 1,
        acceleration: 2, // clamped to 1
      );
      expect(g, closeTo(1 - AccelerationCurve.precisionCut, 1e-12));
      expect(
        AccelerationCurve.gain(-50, pointerSpeed: 1, acceleration: 1),
        closeTo(1 - AccelerationCurve.precisionCut, 1e-12),
      );
    });
  });

  group('PointerAccelerator', () {
    test('slow moves are precise, fast flicks travel further', () {
      final slow = PointerAccelerator();
      final fast = PointerAccelerator();
      var slowTotal = 0.0, fastTotal = 0.0;
      // Same 100 px of finger travel: slowly over 2 s vs quickly in 50 ms.
      for (var i = 1; i <= 100; i++) {
        final (sx, _) = slow.apply(1, 0, i * 20000,
            pointerSpeed: 1, acceleration: 0.7);
        slowTotal += sx;
      }
      for (var i = 1; i <= 10; i++) {
        final (fx, _) = fast.apply(10, 0, i * 5000,
            pointerSpeed: 1, acceleration: 0.7);
        fastTotal += fx;
      }
      expect(slowTotal, lessThan(100));
      expect(fastTotal, greaterThan(100));
      expect(fastTotal, greaterThan(slowTotal * 2));
    });

    test('preserves direction', () {
      final acc = PointerAccelerator();
      final (dx, dy) = acc.apply(-3, 4, 1000, pointerSpeed: 1, acceleration: 0.5);
      expect(dx, lessThan(0));
      expect(dy, greaterThan(0));
      expect(dy / dx, closeTo(4 / -3, 1e-9));
    });

    test('zero dt does not blow up', () {
      final acc = PointerAccelerator();
      acc.apply(1, 1, 1000, pointerSpeed: 1, acceleration: 1);
      final (dx, dy) = acc.apply(1, 1, 1000, pointerSpeed: 1, acceleration: 1);
      expect(dx.isFinite && dy.isFinite, isTrue);
    });
  });

  group('ScrollMapping', () {
    test('natural scrolling: finger up reveals content further down (+dy)', () {
      final (_, dy) =
          ScrollMapping.map(0, -10, scrollSpeed: 1, natural: true);
      expect(dy, greaterThan(0));
    });

    test('traditional scrolling: finger down reveals content further down', () {
      final (_, dy) =
          ScrollMapping.map(0, 10, scrollSpeed: 1, natural: false);
      expect(dy, greaterThan(0));
    });

    test('speed scales the output', () {
      final (x1, _) = ScrollMapping.map(5, 0, scrollSpeed: 1, natural: false);
      final (x2, _) = ScrollMapping.map(5, 0, scrollSpeed: 2, natural: false);
      expect(x2, closeTo(2 * x1, 1e-12));
    });
  });

  group('Inertia', () {
    test('decays and stops', () {
      final i = Inertia(0, 1000);
      final (_, y1) = i.offsetAt(0.1);
      final (_, y2) = i.offsetAt(0.2);
      expect(y1, greaterThan(0));
      expect(y2 - y1, lessThan(y1)); // decelerating
      expect(i.isDone(5), isTrue);
      expect(i.isDone(0), isFalse);
    });

    test('velocity estimator measures recent motion only', () {
      final v = VelocityEstimator();
      // 10 px every 10 ms = 1000 px/s.
      for (var k = 0; k < 10; k++) {
        v.add(0, 10, k * 10000);
      }
      final (_, vy) = v.velocity(90000);
      expect(vy, closeTo(1000, 150));
      // Long after the finger stopped: nothing.
      final (_, stale) = v.velocity(900000);
      expect(stale, 0);
    });
  });

  group('TrackpadEngine', () {
    late List<String> log;
    late TrackpadEngine engine;
    late List<void Function(Duration)> frames;
    var frameUs = 0;

    void pump() {
      while (frames.isNotEmpty) {
        final pending = List.of(frames);
        frames.clear();
        frameUs += 8333;
        for (final cb in pending) {
          cb(Duration(microseconds: frameUs));
        }
        if (frameUs > 10000000) break;
      }
    }

    setUp(() {
      log = <String>[];
      frames = <void Function(Duration)>[];
      engine = TrackpadEngine(
        scheduleFrame: frames.add,
        config: () => const TrackpadConfig(
          pointerSpeed: 1,
          acceleration: 0,
          scrollSpeed: 1,
          naturalScroll: true,
          tapToClick: true,
        ),
        output: TrackpadOutput(
          move: (dx, dy) => log.add('move'),
          scroll: (dx, dy) => log.add('scroll'),
          click: (b, n) => log.add('click $b $n'),
          button: (b, down) => log.add('button $b $down'),
          gesture: (id) => log.add('gesture $id'),
          switchHost: (dir) => log.add('switch $dir'),
          feedback: (_, __) {},
        ),
      );
    });

    tearDown(() => engine.dispose());

    test('tap clicks, quick second tap double-clicks', () {
      engine.pointerDown(1, const ui.Offset(100, 100), 0);
      engine.pointerUp(1, const ui.Offset(100, 100), 80000);
      engine.pointerDown(2, const ui.Offset(102, 101), 200000);
      engine.pointerUp(2, const ui.Offset(102, 101), 260000);
      expect(log, <String>['click ${MouseButton.left} 1', 'click ${MouseButton.left} 2']);
    });

    test('two-finger tap is a right click', () {
      engine.pointerDown(1, const ui.Offset(100, 100), 0);
      engine.pointerDown(2, const ui.Offset(160, 100), 10000);
      engine.pointerUp(1, const ui.Offset(100, 100), 90000);
      engine.pointerUp(2, const ui.Offset(160, 100), 100000);
      expect(log, <String>['click ${MouseButton.right} 1']);
    });

    test('one finger moves, two fingers scroll', () {
      engine.pointerDown(1, const ui.Offset(100, 100), 0);
      for (var i = 1; i <= 5; i++) {
        engine.pointerMove(1, ui.Offset(100.0 + i * 5, 100), i * 8000);
      }
      engine.pointerUp(1, const ui.Offset(125, 100), 50000);
      expect(log.where((e) => e == 'move').length, greaterThan(0));
      expect(log.any((e) => e.startsWith('click')), isFalse);

      log.clear();
      engine.pointerDown(1, const ui.Offset(100, 300), 1000000);
      engine.pointerDown(2, const ui.Offset(160, 300), 1000000);
      for (var i = 1; i <= 6; i++) {
        engine.pointerMove(1, ui.Offset(100, 300.0 - i * 6), 1000000 + i * 8000);
        engine.pointerMove(2, ui.Offset(160, 300.0 - i * 6), 1000000 + i * 8000);
      }
      pump();
      expect(log.where((e) => e == 'scroll').length, greaterThan(0));
      expect(log.contains('move'), isFalse);
    });

    test('moves are coalesced to one per frame and nothing is lost', () {
      final moves = <(double, double)>[];
      final e = TrackpadEngine(
        scheduleFrame: frames.add,
        config: () => const TrackpadConfig(
          pointerSpeed: 1,
          acceleration: 0,
          scrollSpeed: 1,
          naturalScroll: true,
          tapToClick: true,
        ),
        output: TrackpadOutput(
          move: (dx, dy) => moves.add((dx, dy)),
          scroll: (_, __) {},
          click: (_, __) {},
          button: (_, __) {},
          gesture: (_) {},
          switchHost: (_) {},
          feedback: (_, __) {},
        ),
      );
      e.pointerDown(1, const ui.Offset(0, 0), 0);
      // 4 touch events per frame, 3 frames.
      var x = 0.0;
      for (var f = 0; f < 3; f++) {
        for (var k = 0; k < 4; k++) {
          x += 2.5;
          e.pointerMove(1, ui.Offset(x, x / 2), (f * 4 + k + 1) * 2000);
        }
        pump();
      }
      expect(moves.length, 3);
      final sx = moves.fold<double>(0, (a, m) => a + m.$1);
      final sy = moves.fold<double>(0, (a, m) => a + m.$2);
      expect(sx, closeTo(30, 1e-9)); // acceleration 0, speed 1: 1:1
      expect(sy, closeTo(15, 1e-9));
      e.dispose();
    });

    test('scroll fling coasts with per-frame inertia', () {
      engine.pointerDown(1, const ui.Offset(100, 300), 0);
      engine.pointerDown(2, const ui.Offset(160, 300), 0);
      for (var i = 1; i <= 8; i++) {
        engine.pointerMove(1, ui.Offset(100, 300.0 - i * 15), i * 8000);
        engine.pointerMove(2, ui.Offset(160, 300.0 - i * 15), i * 8000);
        pump();
      }
      final before = log.where((e) => e == 'scroll').length;
      engine.pointerUp(1, const ui.Offset(100, 180), 70000);
      engine.pointerUp(2, const ui.Offset(160, 180), 70000);
      expect(engine.isCoasting, isTrue);
      pump();
      expect(engine.isCoasting, isFalse);
      expect(log.where((e) => e == 'scroll').length, greaterThan(before + 5));
    });

    test('three-finger swipe left switches to the next host once', () {
      for (var p = 1; p <= 3; p++) {
        engine.pointerDown(p, ui.Offset(100.0 + p * 40, 300), 0);
      }
      for (var i = 1; i <= 10; i++) {
        for (var p = 1; p <= 3; p++) {
          engine.pointerMove(p, ui.Offset(100.0 + p * 40 - i * 12, 300), i * 8000);
        }
      }
      expect(log, <String>['switch 1']);
    });
  });
}
