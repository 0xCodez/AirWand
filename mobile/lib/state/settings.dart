import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preferences, persisted in shared_preferences.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs) {
    _pointerSpeed = _prefs.getDouble(_kSpeed) ?? 1.2;
    _acceleration = _prefs.getDouble(_kAccel) ?? 0.6;
    _scrollSpeed = _prefs.getDouble(_kScroll) ?? 1.0;
    _naturalScroll = _prefs.getBool(_kNatural) ?? true;
    _haptics = _prefs.getBool(_kHaptics) ?? true;
    _tapToClick = _prefs.getBool(_kTap) ?? true;
    _themeMode = _parseTheme(_prefs.getString(_kTheme));
    _deviceName = _prefs.getString(_kName) ?? _defaultDeviceName();
  }

  static const double minPointerSpeed = 0.4;
  static const double maxPointerSpeed = 3.0;
  static const double minScrollSpeed = 0.3;
  static const double maxScrollSpeed = 3.0;

  static const String _kSpeed = 'orbit.pointerSpeed';
  static const String _kAccel = 'orbit.acceleration';
  static const String _kScroll = 'orbit.scrollSpeed';
  static const String _kNatural = 'orbit.naturalScroll';
  static const String _kHaptics = 'orbit.haptics';
  static const String _kTap = 'orbit.tapToClick';
  static const String _kTheme = 'orbit.theme';
  static const String _kName = 'orbit.deviceName';

  final SharedPreferences _prefs;

  late double _pointerSpeed;
  late double _acceleration;
  late double _scrollSpeed;
  late bool _naturalScroll;
  late bool _haptics;
  late bool _tapToClick;
  late ThemeMode _themeMode;
  late String _deviceName;

  double get pointerSpeed => _pointerSpeed;
  double get acceleration => _acceleration;
  double get scrollSpeed => _scrollSpeed;
  bool get naturalScroll => _naturalScroll;
  bool get haptics => _haptics;
  bool get tapToClick => _tapToClick;
  ThemeMode get themeMode => _themeMode;
  String get deviceName => _deviceName;

  set pointerSpeed(double v) {
    _pointerSpeed = v.clamp(minPointerSpeed, maxPointerSpeed);
    _prefs.setDouble(_kSpeed, _pointerSpeed);
    notifyListeners();
  }

  set acceleration(double v) {
    _acceleration = v.clamp(0.0, 1.0);
    _prefs.setDouble(_kAccel, _acceleration);
    notifyListeners();
  }

  set scrollSpeed(double v) {
    _scrollSpeed = v.clamp(minScrollSpeed, maxScrollSpeed);
    _prefs.setDouble(_kScroll, _scrollSpeed);
    notifyListeners();
  }

  set naturalScroll(bool v) {
    _naturalScroll = v;
    _prefs.setBool(_kNatural, v);
    notifyListeners();
  }

  set haptics(bool v) {
    _haptics = v;
    _prefs.setBool(_kHaptics, v);
    notifyListeners();
  }

  set tapToClick(bool v) {
    _tapToClick = v;
    _prefs.setBool(_kTap, v);
    notifyListeners();
  }

  set themeMode(ThemeMode v) {
    _themeMode = v;
    _prefs.setString(_kTheme, v.name);
    notifyListeners();
  }

  set deviceName(String v) {
    final t = v.trim();
    _deviceName = t.isEmpty ? _defaultDeviceName() : t;
    _prefs.setString(_kName, _deviceName);
    notifyListeners();
  }

  static ThemeMode _parseTheme(String? s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        // Dark is the hero theme.
        return ThemeMode.dark;
    }
  }

  static String _defaultDeviceName() {
    var host = '';
    try {
      host = Platform.localHostname.trim();
    } catch (_) {
      // Host name is not available on every platform; use a generic name.
    }
    final generic = host.isEmpty ||
        host == 'localhost' ||
        host.startsWith('localhost.') ||
        host.toLowerCase() == 'android';
    if (!generic) return host.replaceAll('.local', '');
    return Platform.isIOS ? 'iPhone' : 'Android phone';
  }
}
