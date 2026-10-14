import 'package:cloud_firestore/cloud_firestore.dart';

/// Data model representing platform exchange rates stored in `/system_config/exchange_rates`.
///
/// Base currency is strictly **NGN**. All rates express the value of 1 NGN in target currency units.
class ExchangeRates {
  final String baseCurrency;
  final Map<String, double> rates;
  final DateTime? _lastSyncedAt;
  final int apiCallsThisMonth;
  final String lastSyncedMonth;

  DateTime get lastSyncedAt => _lastSyncedAt ?? DateTime(2026, 1, 1);

  const ExchangeRates({
    this.baseCurrency = 'NGN',
    this.rates = const {
      'NGN': 1.0,
      'USD': 0.00063,
      'EUR': 0.00058,
      'GBP': 0.00049,
      'GHS': 0.0098,
      'XOF': 0.38,
      'XAF': 0.38,
      'KES': 0.081,
      'ZAR': 0.011,
      'CAD': 0.00085,
      'AUD': 0.00095,
    },
    DateTime? lastSyncedAt,
    this.apiCallsThisMonth = 0,
    this.lastSyncedMonth = '',
    // ignore: prefer_initializing_formals
  }) : _lastSyncedAt = lastSyncedAt;

  factory ExchangeRates.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const ExchangeRates();

    final rawRates = map['rates'];
    final parsedRates = <String, double>{'NGN': 1.0};
    if (rawRates is Map) {
      rawRates.forEach((key, val) {
        if (val is num) {
          parsedRates[key.toString().toUpperCase()] = val.toDouble();
        }
      });
    }

    DateTime syncedAt = DateTime.now();
    final rawSynced = map['lastSyncedAt'];
    if (rawSynced is Timestamp) {
      syncedAt = rawSynced.toDate();
    } else if (rawSynced is String) {
      syncedAt = DateTime.tryParse(rawSynced) ?? DateTime.now();
    }

    return ExchangeRates(
      baseCurrency: (map['baseCurrency'] ?? 'NGN').toString(),
      rates: parsedRates.isEmpty
          ? const {
              'NGN': 1.0,
              'USD': 0.00063,
              'EUR': 0.00058,
              'GBP': 0.00049,
              'GHS': 0.0098,
              'XOF': 0.38,
              'XAF': 0.38,
              'KES': 0.081,
              'ZAR': 0.011,
              'CAD': 0.00085,
              'AUD': 0.00095,
            }
          : parsedRates,
      lastSyncedAt: syncedAt,
      apiCallsThisMonth:
          (map['apiCallsThisMonth'] is num) ? (map['apiCallsThisMonth'] as num).toInt() : 0,
      lastSyncedMonth: (map['lastSyncedMonth'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'baseCurrency': baseCurrency,
      'rates': rates,
      'lastSyncedAt': FieldValue.serverTimestamp(),
      'apiCallsThisMonth': apiCallsThisMonth,
      'lastSyncedMonth': lastSyncedMonth,
    };
  }

  /// Converts NGN amount to target currency.
  /// E.g. 1000 NGN to USD (rate = 0.00063) -> 0.63 USD
  double convertFromNgn(double ngnAmount, String targetCurrency) {
    final target = targetCurrency.toUpperCase();
    if (target == 'NGN') return ngnAmount;
    final rate = rates[target];
    if (rate == null || rate <= 0) return ngnAmount;
    return ngnAmount * rate;
  }

  /// Converts foreign currency amount to NGN base currency.
  /// E.g. $10 USD (rate = 0.00063) -> 15873.01 NGN
  double convertToNgn(double foreignAmount, String sourceCurrency) {
    final source = sourceCurrency.toUpperCase();
    if (source == 'NGN') return foreignAmount;
    final rate = rates[source];
    if (rate == null || rate <= 0) return foreignAmount;
    return foreignAmount / rate;
  }

  /// Returns the currency symbol for a standard currency code.
  static String symbolForCurrency(String currencyCode) {
    switch (currencyCode.toUpperCase()) {
      case 'NGN':
        return '₦';
      case 'USD':
        return r'$';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      case 'GHS':
        return '₵';
      case 'KES':
        return 'KSh ';
      case 'ZAR':
        return 'R';
      case 'CAD':
        return r'CA$';
      case 'AUD':
        return r'A$';
      case 'XOF':
        return 'CFA';
      case 'XAF':
        return 'FCFA';
      default:
        return '$currencyCode ';
    }
  }

  /// Formats an NGN base amount dynamically in target currency.
  String formatNgnAmount(
    double ngnAmount,
    String targetCurrency, {
    bool showCode = false,
  }) {
    final target = targetCurrency.toUpperCase();
    final symbol = symbolForCurrency(target);
    final converted = convertFromNgn(ngnAmount, target);
    final formattedNum = _formatWithCommas(converted);
    if (showCode && target != 'NGN') {
      return '$symbol$formattedNum $target';
    }
    return '$symbol$formattedNum';
  }

  static String _formatWithCommas(double amount) {
    final parts = amount.toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
    return '$intPart.${parts[1]}';
  }
}
