import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Automatic Country & Dial Code Detection Utility.
///
/// Detection Flow:
/// 1. Primary Check: Read persistent user override from SharedPreferences
///    (`user_selected_country_code`). Manual user selections are strictly honored.
/// 2. Secondary Check: Physical GPS/device geolocation coordinates via [Geolocator].
///    Determines actual physical country bounding box (Nigeria, Benin, Ghana, Kenya, etc.).
/// 3. Tertiary Check: Device timezone heuristic (West Africa WAT/UTC+1, East Africa EAT/UTC+3).
/// 4. Quaternary Check: Platform locale country code (ONLY if timezone doesn't contradict,
///    preventing standard Android `en_US` system language from falsely reporting `US`).
/// 5. Default Fallback: Default to Nigeria (`NG` / `+234`).
class CountryDetectionService {
  CountryDetectionService._();
  static final CountryDetectionService instance = CountryDetectionService._();

  static const String defaultCountryCode = 'NG';
  static const String defaultDialCode = '+234';
  static const String kSavedCountryKey = 'user_selected_country_code';

  String? _cachedCountryCode;
  bool _hasManualOverride = false;

  /// Whether a manual user country selection is active.
  bool get hasManualOverride => _hasManualOverride;

  /// Resolves country ISO-3166-1 alpha-2 from physical GPS coordinates.
  static String? countryFromCoordinates(double lat, double lng) {
    // Nigeria bounding box: Lat 4.0 to 14.2, Lng 2.5 to 14.8
    if (lat >= 4.0 && lat <= 14.2 && lng >= 2.5 && lng <= 14.8) {
      return 'NG';
    }
    // Benin bounding box: Lat 6.2 to 12.5, Lng 0.7 to 3.9
    if (lat >= 6.2 && lat <= 12.5 && lng >= 0.7 && lng <= 3.9) {
      return 'BJ';
    }
    // Ghana bounding box: Lat 4.7 to 11.2, Lng -3.3 to 1.2
    if (lat >= 4.7 && lat <= 11.2 && lng >= -3.3 && lng <= 1.2) {
      return 'GH';
    }
    // Togo bounding box: Lat 6.1 to 11.2, Lng -0.1 to 1.8
    if (lat >= 6.1 && lat <= 11.2 && lng >= -0.1 && lng <= 1.8) {
      return 'TG';
    }
    // Cameroon bounding box: Lat 1.6 to 13.1, Lng 8.4 to 16.2
    if (lat >= 1.6 && lat <= 13.1 && lng >= 8.4 && lng <= 16.2) {
      return 'CM';
    }
    // Kenya bounding box: Lat -4.7 to 5.5, Lng 33.9 to 41.9
    if (lat >= -4.7 && lat <= 5.5 && lng >= 33.9 && lng <= 41.9) {
      return 'KE';
    }
    // South Africa bounding box: Lat -35.0 to -22.0, Lng 16.0 to 33.0
    if (lat >= -35.0 && lat <= -22.0 && lng >= 16.0 && lng <= 33.0) {
      return 'ZA';
    }
    // United Kingdom: Lat 49.8 to 60.9, Lng -8.6 to 1.8
    if (lat >= 49.8 && lat <= 60.9 && lng >= -8.6 && lng <= 1.8) {
      return 'GB';
    }
    // United States (contiguous): Lat 24.5 to 49.4, Lng -125.0 to -66.9
    if (lat >= 24.5 && lat <= 49.4 && lng >= -125.0 && lng <= -66.9) {
      return 'US';
    }
    // Canada: Lat 41.6 to 83.1, Lng -141.0 to -52.6
    if (lat >= 41.6 && lat <= 83.1 && lng >= -141.0 && lng <= -52.6) {
      return 'CA';
    }
    return null;
  }

  /// Detects the user's ISO-3166-1 alpha-2 country code.
  /// Result is cached in memory for fast synchronous access via [currentCountryCode].
  Future<String> detectCountryCode() async {
    // 1. Primary Check: User-selected country override from SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(kSavedCountryKey)?.trim().toUpperCase();
      if (_isValidAlpha2(saved)) {
        _cachedCountryCode = saved;
        _hasManualOverride = true;
        return saved!;
      }
    } catch (e) {
      debugPrint('CountryDetectionService: SharedPreferences check failed: $e');
    }

    if (_cachedCountryCode != null && _cachedCountryCode!.isNotEmpty) {
      return _cachedCountryCode!;
    }

    String? detected;

    // 2. Secondary Check: Physical Device Geolocation / Coordinates
    try {
      final isServiceEnabled =
          await Geolocator.isLocationServiceEnabled().catchError((_) => false);
      if (isServiceEnabled) {
        final permission = await Geolocator.checkPermission()
            .catchError((_) => LocationPermission.denied);
        if (permission == LocationPermission.always ||
            permission == LocationPermission.whileInUse) {
          // Fast check: last known position (cached on device)
          final lastKnown =
              await Geolocator.getLastKnownPosition().catchError((_) => null);
          if (lastKnown != null) {
            detected = countryFromCoordinates(
                lastKnown.latitude, lastKnown.longitude);
          }
          if (detected == null) {
            // Quick 1.5s timeout attempt to get current low-accuracy fix
            try {
              final curPos = await Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.low,
                  timeLimit: Duration(milliseconds: 1500),
                ),
              );
              detected = countryFromCoordinates(
                  curPos.latitude, curPos.longitude);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('CountryDetectionService: Geolocation check failed: $e');
    }

    // 3. Tertiary Check: Device timezone heuristic
    detected ??= _countryFromTimezone();

    // 4. Quaternary Check: Platform Locale ONLY IF not conflicting with timezone
    if (detected == null) {
      final tzOffset = DateTime.now().timeZoneOffset.inHours;
      // If timezone offset is NOT in North American range (-10 to -4), 'en_US' should NEVER override to US
      try {
        final primaryCode =
            PlatformDispatcher.instance.locale.countryCode?.trim().toUpperCase();
        if (_isValidAlpha2(primaryCode)) {
          final isTzLikelyUs = tzOffset <= -4 && tzOffset >= -10;
          if (primaryCode != 'US' || isTzLikelyUs) {
            detected = primaryCode;
          }
        }
      } catch (e) {
        debugPrint('CountryDetectionService: Primary locale check failed: $e');
      }
    }

    // 5. Default Fallback: Nigeria ('NG')
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

  /// Auto-detects and updates country code from reverse-geocoded address string
  /// (unless overridden manually by user selection).
  void updateFromAddress(String address) {
    if (_hasManualOverride) return;
    if (address.isEmpty) return;
    final upper = address.toUpperCase();

    const countryMap = <String, String>{
      'NIGERIA': 'NG',
      'BENIN': 'BJ',
      'GHANA': 'GH',
      'KENYA': 'KE',
      'CAMEROON': 'CM',
      'TOGO': 'TG',
      'SOUTH AFRICA': 'ZA',
      'UNITED KINGDOM': 'GB',
      'GREAT BRITAIN': 'GB',
      'UNITED STATES': 'US',
      'CANADA': 'CA',
    };

    for (final entry in countryMap.entries) {
      if (upper.contains(entry.key)) {
        setCountryCode(entry.value);
        return;
      }
    }
  }

  /// Updates country code from active GPS coordinates (unless overridden manually by user selection).
  void updateFromCoordinates(double lat, double lng) {
    if (_hasManualOverride) return;
    final code = countryFromCoordinates(lat, lng);
    if (code != null) {
      setCountryCode(code);
    }
  }

  /// Manually override and persist the selected country code to SharedPreferences.
  Future<void> saveManualCountry(String isoCode) async {
    final clean = isoCode.trim().toUpperCase();
    if (_isValidAlpha2(clean)) {
      _cachedCountryCode = clean;
      _hasManualOverride = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kSavedCountryKey, clean);
      } catch (e) {
        debugPrint('CountryDetectionService.saveManualCountry error: $e');
      }
    }
  }

  /// Clears manual override and resets stored preference.
  Future<void> clearManualOverride() async {
    _hasManualOverride = false;
    _cachedCountryCode = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kSavedCountryKey);
    } catch (_) {}
  }

  /// Manually override or prime the detected country code.
  void setCountryCode(String isoCode) {
    if (_isValidAlpha2(isoCode)) {
      _cachedCountryCode = isoCode.toUpperCase();
    }
  }

  /// Clears the cached country code to force re-detection.
  void reset() {
    _cachedCountryCode = null;
    _hasManualOverride = false;
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

      // West Africa Time (WAT) -> UTC+1 (Nigeria, Benin, Cameroon, etc.)
      if (tzName.contains('WAT') ||
          (offsetHours == 1 &&
              (tzName.contains('LAGOS') || tzName.contains('AFRICA')))) {
        return 'NG';
      }
      if (offsetHours == 1) {
        // Any UTC+1 without explicit European timezone defaults to Nigeria
        if (!tzName.contains('CET') &&
            !tzName.contains('BST') &&
            !tzName.contains('PARIS') &&
            !tzName.contains('BERLIN')) {
          return 'NG';
        }
      }
      // East Africa Time (EAT) -> UTC+3 (Kenya, etc.)
      if (tzName.contains('EAT') ||
          tzName.contains('NAIROBI') ||
          (offsetHours == 3 && tzName.contains('AFRICA'))) {
        return 'KE';
      }
      // Ghana / GMT / UTC+0 (West Africa)
      if (offsetHours == 0 &&
          (tzName.contains('ACCRA') || tzName.contains('GHANA'))) {
        return 'GH';
      }
      // GMT / BST -> United Kingdom
      if (tzName.contains('GMT') ||
          tzName.contains('BST') ||
          tzName.contains('LONDON')) {
        return 'GB';
      }
      // Central Africa Time (CAT) / South Africa (SAST) -> UTC+2
      if (tzName.contains('SAST') || tzName.contains('JOHANNESBURG')) {
        return 'ZA';
      }
      // North American Timezones: ONLY if offset is negative (-4 to -10)
      if (offsetHours < 0 &&
          [
            'EST',
            'EDT',
            'CST',
            'CDT',
            'MST',
            'MDT',
            'PST',
            'PDT',
            'AKST',
            'HST'
          ].contains(tzName)) {
        return 'US';
      }
    } catch (_) {
      // Ignore timezone parsing errors
    }
    return null;
  }
}
