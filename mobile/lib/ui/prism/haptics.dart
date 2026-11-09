import 'dart:async';

import 'package:flutter/services.dart';

import '../../state/settings.dart';

/// Static haptics that respect the user's Haptics setting once [bind] has
/// been called (main() does this).
class Haptic {
  Haptic._();

  static AppSettings? _settings;

  static void bind(AppSettings settings) => _settings = settings;

  static bool get _on => _settings?.haptics ?? true;

  /// Keycaps, slider detents, tap-to-click.
  static void tick() {
    if (_on) HapticFeedback.selectionClick();
  }

  static void light() {
    if (_on) HapticFeedback.lightImpact();
  }

  /// Computer switch, drag lock.
  static void medium() {
    if (_on) HapticFeedback.mediumImpact();
  }

  static void heavy() {
    if (_on) HapticFeedback.heavyImpact();
  }

  /// A firm tap followed by a light one.
  static void success() {
    if (!_on) return;
    HapticFeedback.mediumImpact();
    Timer(const Duration(milliseconds: 110), () {
      if (_on) HapticFeedback.lightImpact();
    });
  }

  static void error() {
    if (!_on) return;
    HapticFeedback.heavyImpact();
    Timer(const Duration(milliseconds: 90), HapticFeedback.lightImpact);
    Timer(const Duration(milliseconds: 180), HapticFeedback.lightImpact);
  }
}
