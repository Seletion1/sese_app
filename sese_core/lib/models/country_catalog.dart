// ignore: implementation_imports
import 'package:intl_phone_number_input/src/models/country_list.dart';
/// and associated regional currency details.
class SeseCountryInfo {
  final String countryCode; // ISO 3166-1 alpha-2 (e.g. 'NG')
  final String countryName; // English name (e.g. 'Nigeria')
  final String flagEmoji;   // Flag emoji (e.g. 🇳🇬)
  final String dialCode;    // e.g. '+234'
  final String currencyCode; // e.g. 'NGN'
  final String currencySymbol; // e.g. '₦'

  const SeseCountryInfo({
    required this.countryCode,
    required this.countryName,
    required this.flagEmoji,
    required this.dialCode,
    required this.currencyCode,
    required this.currencySymbol,
  });

  String get displayName => '$flagEmoji $countryName ($countryCode)';
  String get dialDisplayName => '$flagEmoji $countryName ($dialCode)';

  @override
  String toString() => displayName;
}

/// Global System Catalog dynamically deriving countries, dial codes,
/// flags, and currencies from the package's built-in ISO 3166-1 country dataset.
class SeseCountryCatalog {
  SeseCountryCatalog._();

  static List<SeseCountryInfo>? _cachedCountries;
  static Map<String, SeseCountryInfo>? _codeMap;

  /// Default currency mapping for key operational markets.
  /// Any country not in this table defaults to USD ('$').
  static const Map<String, ({String code, String symbol})> _knownCurrencies = {
    'NG': (code: 'NGN', symbol: '₦'),
    'KE': (code: 'KES', symbol: 'KSh '),
    'US': (code: 'USD', symbol: r'$'),
    'GB': (code: 'GBP', symbol: '£'),
    'GH': (code: 'GHS', symbol: '₵'),
    'ZA': (code: 'ZAR', symbol: 'R'),
    'UG': (code: 'UGX', symbol: 'USh'),
    'RW': (code: 'RWF', symbol: 'FRw'),
    'TZ': (code: 'TZS', symbol: 'TSh'),
    'EG': (code: 'EGP', symbol: 'E£'),
    'CA': (code: 'CAD', symbol: r'CA$'),
    'AU': (code: 'AUD', symbol: r'A$'),
    'FR': (code: 'EUR', symbol: '€'),
    'DE': (code: 'EUR', symbol: '€'),
    'ES': (code: 'EUR', symbol: '€'),
    'IT': (code: 'EUR', symbol: '€'),
    'NL': (code: 'EUR', symbol: '€'),
    'AE': (code: 'AED', symbol: 'AED'),
    'SA': (code: 'SAR', symbol: 'SAR'),
    'IN': (code: 'INR', symbol: '₹'),
    'CN': (code: 'CNY', symbol: '¥'),
    'JP': (code: 'JPY', symbol: '¥'),
  };

  /// Converts ISO 3166-1 alpha-2 code to Unicode flag emoji.
  static String countryCodeToEmoji(String code) {
    if (code.length != 2) return '🌐';
    final upper = code.toUpperCase();
    final first = upper.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = upper.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(first) + String.fromCharCode(second);
  }

  /// Returns the complete list of countries generated dynamically from
  /// the phone package's built-in ISO 3166-1 dataset.
  static List<SeseCountryInfo> get allCountries {
    if (_cachedCountries != null) return _cachedCountries!;

    final map = <String, SeseCountryInfo>{};
    for (final raw in Countries.countryList) {
      final code = (raw['alpha_2_code'] ?? '').toString().toUpperCase();
      if (code.isEmpty || code.length != 2) continue;

      final name = (raw['en_short_name'] ?? code).toString();
      final dial = (raw['dial_code'] ?? '').toString();
      final flag = countryCodeToEmoji(code);

      final curr = _knownCurrencies[code] ?? (code: 'USD', symbol: r'$');

      map[code] = SeseCountryInfo(
        countryCode: code,
        countryName: name,
        flagEmoji: flag,
        dialCode: dial,
        currencyCode: curr.code,
        currencySymbol: curr.symbol,
      );
    }

    _codeMap = map;

    // Sort with primary markets first (NG, KE, GH, US, GB, etc.), then alphabetically
    const priority = ['NG', 'KE', 'GH', 'ZA', 'UG', 'RW', 'TZ', 'US', 'GB', 'CA'];
    final list = map.values.toList()
      ..sort((a, b) {
        final aPrio = priority.indexOf(a.countryCode);
        final bPrio = priority.indexOf(b.countryCode);
        if (aPrio != -1 && bPrio != -1) return aPrio.compareTo(bPrio);
        if (aPrio != -1) return -1;
        if (bPrio != -1) return 1;
        return a.countryName.compareTo(b.countryName);
      });

    _cachedCountries = list;
    return list;
  }

  /// Locates country metadata by ISO alpha-2 code (case-insensitive).
  static SeseCountryInfo? findByCode(String countryCode) {
    if (_codeMap == null) {
      allCountries; // primes the map
    }
    return _codeMap?[countryCode.trim().toUpperCase()];
  }

  /// Finds country metadata by international dial code (e.g. '+234' or '234').
  static SeseCountryInfo? findByDialCode(String dialCode) {
    final clean = dialCode.startsWith('+') ? dialCode : '+$dialCode';
    for (final c in allCountries) {
      if (c.dialCode == clean) return c;
    }
    return null;
  }

  /// Resolves the regional currency code for a given country code (e.g. 'NG' -> 'NGN').
  static String getCurrencyForCountry(String countryCode) {
    final info = findByCode(countryCode);
    return info?.currencyCode ?? 'USD';
  }

  /// Resolves the currency symbol for a given currency code (e.g. 'NGN' -> '₦').
  static String getCurrencySymbolForCode(String currencyCode) {
    final upper = currencyCode.trim().toUpperCase();
    switch (upper) {
      case 'NGN':
        return '₦';
      case 'KES':
        return 'KSh ';
      case 'USD':
        return r'$';
      case 'GBP':
        return '£';
      case 'EUR':
        return '€';
      case 'GHS':
        return '₵';
      case 'ZAR':
        return 'R';
      case 'CAD':
        return r'CA$';
      case 'AUD':
        return r'A$';
      default:
        return r'$';
    }
  }

  /// List of distinct active operational currencies across all countries.
  static List<({String code, String symbol})> get operationalCurrencies {
    return const [
      (code: 'NGN', symbol: '₦'),
      (code: 'KES', symbol: 'KSh '),
      (code: 'USD', symbol: r'$'),
      (code: 'GBP', symbol: '£'),
      (code: 'EUR', symbol: '€'),
      (code: 'GHS', symbol: '₵'),
      (code: 'ZAR', symbol: 'R'),
    ];
  }
}
