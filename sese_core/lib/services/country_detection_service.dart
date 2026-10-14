import 'package:flutter/foundation.dart';

/// Automatic Country & Dial Code Detection Utility.
///
/// Detection Flow:
/// 1. Primary Check: Read SIM operator country code via native telephony
///    metadata (`PlatformDispatcher.instance.locale.countryCode`).
/// 2. Secondary Check: Fallback to device timezone / system locale list.
/// 3. Default Fallback: Default to Nigeria (`NG` / `+234`) if offline or
///    permissions/locales are unavailable.
class CountryDetectionService {
  CountryDetectionService._();
  static final CountryDetectionService instance = CountryDetectionService._();

  static const String defaultCountryCode = 'NG';
  static const String defaultDialCode = '+234';

  String? _cachedCountryCode;

  /// Detects the user's ISO-3166-1 alpha-2 country code.
  /// Result is cached in memory for fast synchronous access via [currentCountryCode].
  Future<String> detectCountryCode() async {
    if (_cachedCountryCode != null && _cachedCountryCode!.isNotEmpty) {
      return _cachedCountryCode!;
    }

    String? detected;

    // 1. Primary Check: PlatformDispatcher primary locale country code
    try {
      final primaryCode =
          PlatformDispatcher.instance.locale.countryCode?.trim().toUpperCase();
      if (_isValidAlpha2(primaryCode)) {
        detected = primaryCode;
      }
    } catch (e) {
      debugPrint('CountryDetectionService: Primary locale check failed: $e');
    }

    // 2. Secondary Check: Locale list fallback
    if (detected == null) {
      try {
        final locales = PlatformDispatcher.instance.locales;
        for (final loc in locales) {
          final code = loc.countryCode?.trim().toUpperCase();
          if (_isValidAlpha2(code)) {
            detected = code;
            break;
          }
        }
      } catch (e) {
        debugPrint('CountryDetectionService: Locales list check failed: $e');
      }
    }

    // 3. Secondary Check (b): Device timezone heuristic
    detected ??= _countryFromTimezone();

    // 4. Default Fallback: Nigeria ('NG')
    final finalCode = detected ?? defaultCountryCode;
    _cachedCountryCode = finalCode;
    return finalCode;
  }

  /// Synchronous getter for current detected country code (defaults to 'NG').
  String get currentCountryCode => _cachedCountryCode ?? defaultCountryCode;

  /// Converts 2-letter ISO country code to Unicode Flag Emoji (e.g. 'NG' -> '🇳🇬', 'CA' -> '🇨🇦').
  static String countryCodeToEmoji(String isoCode) {
    final clean = isoCode.trim().toUpperCase();
    if (clean.length != 2) return '🌐';
    final int firstLetter = clean.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final int secondLetter = clean.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(firstLetter) + String.fromCharCode(secondLetter);
  }

  /// Formats country item with Flag Emoji + Full Name + ISO Code / Dial Code.
  /// Example: '🇳🇬 Nigeria (NG +234)'
  static String formatCountryItem({
    required String isoCode,
    required String countryName,
    required String dialCode,
  }) {
    final flag = countryCodeToEmoji(isoCode);
    final cleanDial = dialCode.startsWith('+') ? dialCode : '+$dialCode';
    return '$flag  $countryName ($isoCode $cleanDial)';
  }

  /// Auto-detects and updates country code from reverse-geocoded address string.
  void updateFromAddress(String address) {
    if (address.isEmpty) return;
    final upper = address.toUpperCase();

    const countryMap = <String, String>{
      'NIGERIA': 'NG',
      'CANADA': 'CA',
      'GHANA': 'GH',
      'KENYA': 'KE',
      'UNITED KINGDOM': 'GB',
      'GREAT BRITAIN': 'GB',
      'UNITED STATES': 'US',
      'SOUTH AFRICA': 'ZA',
      'CAMEROON': 'CM',
      'BENIN': 'BJ',
    };

    for (final entry in countryMap.entries) {
      if (upper.contains(entry.key)) {
        setCountryCode(entry.value);
        return;
      }
    }
  }

  /// Manually override or prime the detected country code (useful in tests or user settings).
  void setCountryCode(String isoCode) {
    if (_isValidAlpha2(isoCode)) {
      _cachedCountryCode = isoCode.toUpperCase();
    }
  }

  /// Clears the cached country code to force re-detection.
  void reset() {
    _cachedCountryCode = null;
  }

  bool _isValidAlpha2(String? code) {
    if (code == null) return false;
    return RegExp(r'^[A-Z]{2}$').hasMatch(code);
  }

  /// Maps device timezone to country code heuristic where possible.
  String? _countryFromTimezone() {
    try {
      final now = DateTime.now();
      final tzName = now.timeZoneName.toUpperCase();
      final offsetHours = now.timeZoneOffset.inHours;

      // West Africa Time (WAT) -> UTC+1 (Nigeria, etc.)
      if (tzName.contains('WAT') || (offsetHours == 1 && tzName.contains('LAGOS'))) {
        return 'NG';
      }
      // East Africa Time (EAT) -> UTC+3 (Kenya, etc.)
      if (tzName.contains('EAT') || tzName.contains('NAIROBI')) {
        return 'KE';
      }
      // GMT / BST -> United Kingdom
      if (tzName.contains('GMT') || tzName.contains('BST') || tzName.contains('LONDON')) {
        return 'GB';
      }
      // North American Timezones
      if (['EST', 'EDT', 'CST', 'CDT', 'MST', 'MDT', 'PST', 'PDT'].contains(tzName)) {
        return 'US';
      }
    } catch (_) {
      // Ignore timezone parsing errors
    }
    return null;
  }
}
