import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage saved device preferences
class DevicePreferences {
  static const String _keyDeviceType = 'saved_device_type';
  static const String _keyDeviceId = 'saved_device_id';
  static const String _keyDeviceName = 'saved_device_name';
  static const String _keyIsSaved = 'is_device_saved';

  /// Save the selected device type and connected Bluetooth device
  static Future<void> saveDevice({
    required String deviceType,
    required String deviceId,
    required String deviceName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDeviceType, deviceType);
    await prefs.setString(_keyDeviceId, deviceId);
    await prefs.setString(_keyDeviceName, deviceName);
    await prefs.setBool(_keyIsSaved, true);
  }

  /// Clear saved device preferences
  static Future<void> clearDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyDeviceType);
    await prefs.remove(_keyDeviceId);
    await prefs.remove(_keyDeviceName);
    await prefs.setBool(_keyIsSaved, false);
  }

  /// Check if a device is saved
  static Future<bool> hasSavedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIsSaved) ?? false;
  }

  /// Get saved device type (EDLI or ELS)
  static Future<String?> getSavedDeviceType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceType);
  }

  /// Get saved device ID (MAC address)
  static Future<String?> getSavedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceId);
  }

  /// Get saved device name
  static Future<String?> getSavedDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceName);
  }

  /// Get all saved device info
  static Future<Map<String, String?>> getSavedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'type': prefs.getString(_keyDeviceType),
      'id': prefs.getString(_keyDeviceId),
      'name': prefs.getString(_keyDeviceName),
    };
  }
}
