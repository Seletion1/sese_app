import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centralized local-first caching service leveraging SharedPreferences.
/// Instantaneously saves and restores last-known application states to avoid
/// blank screens and blocking network spinners on startup or tab switches.
class LocalCacheService {
  static final LocalCacheService instance = LocalCacheService._internal();
  LocalCacheService._internal();

  SharedPreferences? _prefs;

  /// Ensures SharedPreferences instance is primed synchronously.
  Future<void> init() async {
    if (_prefs == null) {
      try {
        _prefs = await SharedPreferences.getInstance();
      } catch (e) {
        debugPrint('LocalCacheService init error: $e');
      }
    }
  }

  /// Writes a JSON map to local persistent cache under [key].
  Future<bool> setJsonMap(String key, Map<String, dynamic> data) async {
    await init();
    if (_prefs == null) return false;
    try {
      final jsonString = jsonEncode(data);
      return await _prefs!.setString(key, jsonString);
    } catch (e) {
      debugPrint('LocalCacheService setJsonMap error ($key): $e');
      return false;
    }
  }

  /// Reads a cached JSON map under [key], returning null if unavailable or expired.
  Map<String, dynamic>? getJsonMap(String key) {
    if (_prefs == null) return null;
    final jsonString = _prefs!.getString(key);
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (e) {
      debugPrint('LocalCacheService getJsonMap decode error ($key): $e');
    }
    return null;
  }

  /// Writes a list of JSON maps under [key].
  Future<bool> setJsonList(String key, List<Map<String, dynamic>> data) async {
    await init();
    if (_prefs == null) return false;
    try {
      final jsonString = jsonEncode(data);
      return await _prefs!.setString(key, jsonString);
    } catch (e) {
      debugPrint('LocalCacheService setJsonList error ($key): $e');
      return false;
    }
  }

  /// Reads a cached list of JSON maps under [key].
  List<Map<String, dynamic>>? getJsonList(String key) {
    if (_prefs == null) return null;
    final jsonString = _prefs!.getString(key);
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('LocalCacheService getJsonList decode error ($key): $e');
    }
    return null;
  }

  /// Stores a string value synchronously.
  Future<bool> setString(String key, String value) async {
    await init();
    return _prefs?.setString(key, value) ?? Future.value(false);
  }

  /// Reads a string value.
  String? getString(String key) {
    return _prefs?.getString(key);
  }

  /// Stores an integer value.
  Future<bool> setInt(String key, int value) async {
    await init();
    return _prefs?.setInt(key, value) ?? Future.value(false);
  }

  /// Reads an integer value.
  int? getInt(String key) {
    return _prefs?.getInt(key);
  }

  /// Stores a boolean value.
  Future<bool> setBool(String key, bool value) async {
    await init();
    return _prefs?.setBool(key, value) ?? Future.value(false);
  }

  /// Reads a boolean value.
  bool? getBool(String key) {
    return _prefs?.getBool(key);
  }

  /// Clears a cached key.
  Future<bool> remove(String key) async {
    await init();
    return _prefs?.remove(key) ?? Future.value(false);
  }
}
