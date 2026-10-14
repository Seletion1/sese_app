import 'package:sese_core/services/country_detection_service.dart';

/// Result of parsing a raw phone string for country dial code and national number.
class ParsedPhoneNumber {
  final String isoCode;
  final String dialCode;
  final String nationalNumber;
  final String e164;
  final bool hasExplicitCountryPrefix;

  const ParsedPhoneNumber({
    required this.isoCode,
    required this.dialCode,
    required this.nationalNumber,
    required this.e164,
    required this.hasExplicitCountryPrefix,
  });
}

/// E.164 Normalization & Leading Zero Sanitization Engine.
///
/// Ensures phone numbers are normalized to strict E.164 format (e.g., `+2348012345678`)
/// before persisting to Firestore or passing to Firebase Auth.
///
/// Sanitization Rules:
/// - Automatically strips all non-digit characters (except a leading '+').
/// - Strips leading zeros when appending national numbers to country codes:
///   e.g. "+234" + "08012345678" -> "+2348012345678"
///   e.g. "+23408012345678" -> "+2348012345678"
///   e.g. "08012345678" (defaulting to NG) -> "+2348012345678"
/// - Validates strict E.164 compliance: `^\+[1-9]\d{6,14}$`.
class SesePhoneSanitizer {
  SesePhoneSanitizer._();

  /// Known dial codes mapped to default ISO alpha-2 codes.
  static const Map<String, String> dialCodeToIso = {
    '234': 'NG',
    '254': 'KE',
    '1': 'US',
    '44': 'GB',
    '233': 'GH',
    '27': 'ZA',
    '256': 'UG',
    '250': 'RW',
    '255': 'TZ',
    '20': 'EG',
    '33': 'FR',
    '49': 'DE',
    '91': 'IN',
    '86': 'CN',
    '81': 'JP',
    '971': 'AE',
    '966': 'SA',
    '237': 'CM',
    '225': 'CI',
    '221': 'SN',
  };

  /// ISO alpha-2 to dial code mapping.
  static const Map<String, String> isoToDialCode = {
    'NG': '+234',
    'KE': '+254',
    'US': '+1',
    'GB': '+44',
    'GH': '+233',
    'ZA': '+27',
    'UG': '+256',
    'RW': '+250',
    'TZ': '+255',
    'EG': '+20',
    'FR': '+33',
    'DE': '+49',
    'IN': '+91',
    'CN': '+86',
    'JP': '+81',
    'AE': '+971',
    'SA': '+966',
    'CM': '+237',
    'CI': '+225',
    'SN': '+221',
  };

  /// Gets the international dial code for an ISO alpha-2 country code.
  /// Defaults to '+234' (Nigeria).
  static String getDialCode(String? isoCode) {
    if (isoCode == null || isoCode.isEmpty) return CountryDetectionService.defaultDialCode;
    return isoToDialCode[isoCode.toUpperCase()] ?? CountryDetectionService.defaultDialCode;
  }

  /// Parses a raw phone string to auto-detect country dial code and national digits.
  static ParsedPhoneNumber parse(String rawInput, {String? defaultIsoCode}) {
    final trimmed = rawInput.trim();
    final defaultIso = (defaultIsoCode != null && defaultIsoCode.isNotEmpty)
        ? defaultIsoCode.toUpperCase()
        : CountryDetectionService.instance.currentCountryCode;
    final defaultDial = getDialCode(defaultIso);

    if (trimmed.isEmpty) {
      return ParsedPhoneNumber(
        isoCode: defaultIso,
        dialCode: defaultDial,
        nationalNumber: '',
        e164: '',
        hasExplicitCountryPrefix: false,
      );
    }

    String digitsOnly = trimmed.replaceAll(RegExp(r'[\s\(\)\-\.]'), '');

    // 1. If starts with '+', parse exact country dial code
    if (digitsOnly.startsWith('+')) {
      final withoutPlus = digitsOnly.substring(1);
      for (final len in [3, 2, 1]) {
        if (withoutPlus.length >= len) {
          final prefix = withoutPlus.substring(0, len);
          if (dialCodeToIso.containsKey(prefix)) {
            final iso = dialCodeToIso[prefix]!;
            String rest = withoutPlus.substring(len);
            while (rest.startsWith(prefix)) {
              rest = rest.substring(prefix.length);
            }
            return ParsedPhoneNumber(
              isoCode: iso,
              dialCode: '+$prefix',
              nationalNumber: rest,
              e164: normalize(trimmed, defaultIsoCode: iso),
              hasExplicitCountryPrefix: true,
            );
          }
        }
      }
    }

    // 2. If starts with dial code without '+' (e.g. 2348161561592)
    for (final len in [3, 2, 1]) {
      if (digitsOnly.length >= len + 7) {
        final prefix = digitsOnly.substring(0, len);
        if (dialCodeToIso.containsKey(prefix)) {
          final iso = dialCodeToIso[prefix]!;
          String rest = digitsOnly.substring(len);
          while (rest.startsWith(prefix)) {
            rest = rest.substring(prefix.length);
          }
          return ParsedPhoneNumber(
            isoCode: iso,
            dialCode: '+$prefix',
            nationalNumber: rest,
            e164: normalize(trimmed, defaultIsoCode: iso),
            hasExplicitCountryPrefix: true,
          );
        }
      }
    }

    // 3. Plain local national number (e.g. 08012345678 or 8012345678)
    return ParsedPhoneNumber(
      isoCode: defaultIso,
      dialCode: defaultDial,
      nationalNumber: digitsOnly,
      e164: normalize(trimmed, defaultIsoCode: defaultIso),
      hasExplicitCountryPrefix: false,
    );
  }

  /// Removes duplicate leading dial codes and leading zeros from raw input.
  static String cleanPhoneNumber(String input, String dialCode) {
    String cleaned = input.replaceAll(RegExp(r'\D'), ''); // Keep digits only
    String codeDigits = dialCode.replaceAll(RegExp(r'\D'), '');

    // Remove duplicate leading country codes if pasted or typed
    while (codeDigits.isNotEmpty && cleaned.startsWith(codeDigits)) {
      cleaned = cleaned.substring(codeDigits.length);
    }
    // Strip leading 0 if present (e.g. 0815... -> 815...)
    while (cleaned.startsWith('0')) {
      cleaned = cleaned.substring(1);
    }
    return cleaned;
  }

  /// Normalizes any raw phone input to strict E.164 format.
  ///
  /// Examples:
  /// - `08012345678` -> `+2348012345678`
  /// - `+23408012345678` -> `+2348012345678`
  /// - `2348012345678` -> `+2348012345678`
  /// - `+234+2348012345678` -> `+2348012345678`
  /// - `+234 801-234-5678` -> `+2348012345678`
  /// - `+44 07911 123456` -> `+447911123456`
  /// - `+1 (555) 012-3456` -> `+15550123456`
  static String normalize(String rawPhone, {String? defaultIsoCode}) {
    final trimmed = rawPhone.trim();
    if (trimmed.isEmpty) return '';

    final iso = (defaultIsoCode != null && defaultIsoCode.isNotEmpty)
        ? defaultIsoCode.toUpperCase()
        : CountryDetectionService.instance.currentCountryCode;
    final fallbackDial = getDialCode(iso);

    // 1. Remove all spaces, parentheses, hyphens, dots
    String digitsOnly = trimmed.replaceAll(RegExp(r'[\s\(\)\-\.]'), '');

    // 2. If it begins with '+', extract dial code and national number
    if (digitsOnly.startsWith('+')) {
      final withoutPlus = digitsOnly.substring(1);
      // Check known dial codes from longest (3 digits) to shortest (1 digit)
      String? matchedDial;
      for (final len in [3, 2, 1]) {
        if (withoutPlus.length >= len) {
          final prefix = withoutPlus.substring(0, len);
          if (dialCodeToIso.containsKey(prefix)) {
            matchedDial = prefix;
            break;
          }
        }
      }

      if (matchedDial != null) {
        String rest = withoutPlus.substring(matchedDial.length);
        // SANITIZATION RULE: Remove duplicate dial code if repeated
        while (rest.startsWith(matchedDial)) {
          rest = rest.substring(matchedDial.length);
        }
        // SANITIZATION RULE: Strip leading zero(s) after dial code
        while (rest.startsWith('0')) {
          rest = rest.substring(1);
        }
        return '+$matchedDial$rest';
      }

      return '+$withoutPlus';
    }

    // 3. If it starts with known dial code digits without '+' (e.g. 234801...)
    for (final len in [3, 2, 1]) {
      if (digitsOnly.length >= len + 7) {
        final prefix = digitsOnly.substring(0, len);
        if (dialCodeToIso.containsKey(prefix)) {
          String rest = digitsOnly.substring(len);
          // SANITIZATION RULE: Remove duplicate dial code if repeated
          while (rest.startsWith(prefix)) {
            rest = rest.substring(prefix.length);
          }
          // SANITIZATION RULE: Strip leading zero(s)
          while (rest.startsWith('0')) {
            rest = rest.substring(1);
          }
          return '+$prefix$rest';
        }
      }
    }

    // 4. Local national number (e.g. 08012345678 or 8012345678)
    // SANITIZATION RULE: Strip leading zero(s) before appending to dial code
    String national = digitsOnly;
    while (national.startsWith('0')) {
      national = national.substring(1);
    }

    return '$fallbackDial$national';
  }

  /// Verifies if a normalized phone number complies with ITU-T E.164.
  /// (Must begin with '+', followed by 7 to 15 digits, starting with 1-9).
  static bool isValidE164(String? phone) {
    if (phone == null || phone.isEmpty) return false;
    return RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(phone);
  }

  /// Helper for Nigerian phone validation.
  static bool isValidNigerianNumber(String? phone) {
    if (phone == null || phone.isEmpty) return false;
    final normalized = normalize(phone, defaultIsoCode: 'NG');
    return RegExp(r'^\+234[789]\d{9}$').hasMatch(normalized);
  }
}
