import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../net/protocol.dart';

/// This phone's persistent 16-byte deviceId.
class DeviceIdentity {
  DeviceIdentity._(this.deviceId) : hex = hexEncode(deviceId);

  static const String _key = 'orbit.deviceId.v1';

  final Uint8List deviceId;
  final String hex;

  /// `ios` or `android` (Solana Seeker/Saga report `android`).
  static String get platform => Platform.isIOS ? 'ios' : 'android';

  static Future<DeviceIdentity> load(SharedPreferences prefs) async {
    final stored = prefs.getString(_key);
    if (stored != null && stored.length == Proto.idLength * 2) {
      try {
        return DeviceIdentity._(hexDecode(stored));
      } on FormatException {
        // fall through and regenerate
      }
    }
    final id = randomBytes(Proto.idLength);
    await prefs.setString(_key, hexEncode(id));
    return DeviceIdentity._(id);
  }
}
