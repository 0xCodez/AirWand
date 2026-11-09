import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/control.dart';
import '../net/hosts.dart';
import 'identity.dart';
import 'settings.dart';

/// Haptics that respect the user's setting (DESIGN.md "Haptics").
class Haptics {
  Haptics(this._settings);

  final AppSettings _settings;

  bool get _on => _settings.haptics;

  /// Tap-to-click, keycaps, slider steps.
  void selection() {
    if (_on) HapticFeedback.selectionClick();
  }

  /// Mode change, small confirmations.
  void light() {
    if (_on) HapticFeedback.lightImpact();
  }

  /// Computer switch, drag start.
  void medium() {
    if (_on) HapticFeedback.mediumImpact();
  }

  void heavy() {
    if (_on) HapticFeedback.heavyImpact();
  }

  /// "Success notification": a firm tap followed by a light one.
  void success() {
    if (!_on) return;
    HapticFeedback.mediumImpact();
    Timer(const Duration(milliseconds: 110), HapticFeedback.lightImpact);
  }

  /// Failure: three quick light taps.
  void error() {
    if (!_on) return;
    HapticFeedback.heavyImpact();
    Timer(const Duration(milliseconds: 90), HapticFeedback.lightImpact);
    Timer(const Duration(milliseconds: 180), HapticFeedback.lightImpact);
  }
}

/// App-wide services, created once in main().
class AirWandServices {
  AirWandServices._({
    required this.prefs,
    required this.settings,
    required this.identity,
    required this.hosts,
    required this.control,
    required this.haptics,
  });

  final SharedPreferences prefs;
  final AppSettings settings;
  final DeviceIdentity identity;
  final HostStore hosts;
  final ControlClient control;
  final Haptics haptics;

  static Future<AirWandServices> create(SharedPreferences prefs) async {
    final settings = AppSettings(prefs);
    final identity = await DeviceIdentity.load(prefs);
    final hosts = HostStore(prefs);
    final control = ControlClient(deviceId: identity.deviceId);
    control.onHostOs = (id, os) => hosts.updateEndpoint(id, os: os);
    return AirWandServices._(
      prefs: prefs,
      settings: settings,
      identity: identity,
      hosts: hosts,
      control: control,
      haptics: Haptics(settings),
    );
  }
}

class AirWandScope extends InheritedWidget {
  const AirWandScope({super.key, required this.services, required super.child});

  final AirWandServices services;

  static AirWandServices of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AirWandScope>();
    assert(scope != null, 'AirWandScope missing above this widget');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AirWandScope oldWidget) =>
      services != oldWidget.services;
}
