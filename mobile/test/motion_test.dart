import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/motion/one_euro.dart';
import 'package:orbit/motion/spring.dart';

void main() {
  group('OneEuroFilter', () {
    test('constant signal is unchanged', () {
      final f = OneEuroFilter();
      for (var i = 0; i < 100; i++) {
        expect(f.filter(500, i / 60), closeTo(500, 1e-9));
      }
    });

    test('attenuates jitter', () {
      final f = OneEuroFilter(minCutoff: 1, beta: 0.007);
      var out = 0.0;
      for (var i = 0; i < 600; i++) {
        out = f.filter(100.0 + (i.isEven ? 3 : -3), i / 60);
      }
      expect((out - 100).abs(), lessThan(1.5));
    });

    test('beta reduces lag on fast motion', () {
      final slow = OneEuroFilter(minCutoff: 1, beta: 0);
      final fast = OneEuroFilter(minCutoff: 1, beta: 0.05);
      var a = 0.0, b = 0.0;
      for (var i = 0; i < 30; i++) {
        a = slow.filter(i * 40.0, i / 60);
        b = fast.filter(i * 40.0, i / 60);
      }
      expect(b, greaterThan(a));
    });

    test('duplicate timestamps and reset are safe', () {
      final f = OneEuroFilter();
      f.filter(1, 0);
      expect(f.filter(2, 0).isFinite, isTrue);
      f.reset();
      expect(f.hasValue, isFalse);
      expect(f.filter(42, 5), 42);
    });
  });

  group('Spring', () {
    for (final damping in <double>[0.5, 1.0, 1.6]) {
      test('settles on target (damping $damping)', () {
        final s = Spring(response: 0.3, damping: damping);
        s.target = 100;
        var t = 0.0;
        while (s.isMoving && t < 5) {
          s.step(1 / 120);
          t += 1 / 120;
        }
        expect(s.value, 100);
        expect(s.velocity, 0);
        expect(t, lessThan(damping > 1 ? 3.0 : 1.5));
      });
    }

    test('critically damped does not overshoot', () {
      final s = Spring(response: 0.25, damping: 1);
      s.target = 50;
      for (var i = 0; i < 240; i++) {
        s.step(1 / 240);
        expect(s.value, lessThanOrEqualTo(50 + 1e-9));
      }
    });

    test('underdamped overshoots', () {
      final s = Spring(response: 0.3, damping: 0.4);
      s.target = 50;
      var peak = 0.0;
      for (var i = 0; i < 240; i++) {
        peak = s.step(1 / 240) > peak ? s.value : peak;
      }
      expect(peak, greaterThan(50));
    });

    test('is frame-rate independent', () {
      for (final damping in <double>[0.6, 1.0, 1.4]) {
        final a = Spring(response: 0.35, damping: damping)..target = 80;
        final b = Spring(response: 0.35, damping: damping)..target = 80;
        for (var i = 0; i < 12; i++) {
          a.step(1 / 60);
        }
        for (var i = 0; i < 48; i++) {
          b.step(1 / 240);
        }
        expect(a.value, closeTo(b.value, 1e-6));
        expect(a.velocity, closeTo(b.velocity, 1e-5));
      }
    });

    test('retargeting mid-flight keeps velocity (no jumps)', () {
      final s = Spring(response: 0.3, damping: 0.9)..target = 100;
      for (var i = 0; i < 10; i++) {
        s.step(1 / 120);
      }
      final before = s.value;
      s.target = -100;
      s.step(1 / 120);
      expect((s.value - before).abs(), lessThan(10));
    });

    test('Spring2D follows a target and snaps', () {
      final s = Spring2D(response: 0.18, damping: 0.85);
      s.snapTo(10, 20);
      expect(s.isMoving, isFalse);
      s.setTarget(110, -80);
      for (var i = 0; i < 240; i++) {
        s.step(1 / 120);
      }
      expect(s.x, closeTo(110, 0.02));
      expect(s.y, closeTo(-80, 0.02));
    });

    test('zero / garbage dt is a no-op', () {
      final s = Spring()..target = 10;
      expect(s.step(0), 0);
      expect(s.step(double.nan), 0);
    });
  });
}
