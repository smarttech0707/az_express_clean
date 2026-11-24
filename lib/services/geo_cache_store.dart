import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class GeoCacheStore {
  const GeoCacheStore._();

  static Future<Map<String, dynamic>> read(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return {};
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> write(String key, Map<String, dynamic> value) async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(key, jsonEncode(value));
    } catch (_) {}
  }
}
