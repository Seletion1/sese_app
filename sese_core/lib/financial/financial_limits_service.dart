import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'exchange_rate_service.dart';
import 'exchange_rates.dart';
import 'financial_limits_config.dart';

/// Service streaming, reading, and saving `/system_config/financial_limits`.
///
/// Provides dynamic multi-currency conversions for financial limits using
/// [ExchangeRateService].
class FinancialLimitsService {
  final FirebaseFirestore? firestore;
  final ExchangeRateService exchangeRateService;

  const FinancialLimitsService({
    this.firestore,
    this.exchangeRateService = const ExchangeRateService(),
  });

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Live stream of `/system_config/financial_limits`.
  Stream<FinancialLimitsConfig> streamLimits() {
    final db = _db;
    if (db == null) return Stream.value(const FinancialLimitsConfig());
    return db
        .collection('system_config')
        .doc('financial_limits')
        .snapshots()
        .map((snap) => FinancialLimitsConfig.fromMap(snap.data()))
        .handleError((Object error) {
      debugPrint('FinancialLimitsService.streamLimits error: $error');
      return const FinancialLimitsConfig();
    });
  }

  /// One-shot fetch of `/system_config/financial_limits`.
  Future<FinancialLimitsConfig> fetchLimits() async {
    try {
      final db = _db;
      if (db == null) return const FinancialLimitsConfig();
      final snap = await db.collection('system_config').doc('financial_limits').get();
      return FinancialLimitsConfig.fromMap(snap.data());
    } catch (e) {
      debugPrint('FinancialLimitsService.fetchLimits error: $e');
      return const FinancialLimitsConfig();
    }
  }

  /// Saves financial limits configuration to `/system_config/financial_limits`.
  Future<void> saveLimits(FinancialLimitsConfig config) async {
    final db = _db;
    if (db == null) throw StateError('Firebase is not initialized.');
    await db
        .collection('system_config')
        .doc('financial_limits')
        .set(config.toMap(), SetOptions(merge: true));
  }

  /// Evaluates whether a proposed top-up amount satisfies the single-transaction
  /// and balance caps for a user, accounting for currency conversion.
  ///
  /// Returns `null` if valid, or a localized, user-friendly error message if blocked.
  Future<String?> validateTopUp({
    required double amount,
    required String currency,
    required double currentBalance,
    required String role,
    required bool isKycVerified,
  }) async {
    final limits = await fetchLimits();
    final rates = await exchangeRateService.fetchExchangeRates();

    // Convert amount and balance to base Naira for evaluation
    final amountNgn = rates.convertToNgn(amount, currency);
    final currentBalanceNgn = rates.convertToNgn(currentBalance, currency);

    final minNgn = limits.minTopUpFor(role);
    final maxSingleNgn = limits.maxSingleTopUpFor(role);
    final balanceCapNgn = limits.maxWalletBalanceFor(
      role: role,
      isKycVerified: isKycVerified,
    );

    final symbol = ExchangeRates.symbolForCurrency(currency);

    if (amountNgn < minNgn) {
      final convertedMin = rates.convertFromNgn(minNgn, currency);
      return 'Minimum top-up is $symbol${convertedMin.toStringAsFixed(convertedMin < 10 ? 2 : 0)}.';
    }

    if (amountNgn > maxSingleNgn) {
      final convertedMax = rates.convertFromNgn(maxSingleNgn, currency);
      return 'Maximum single top-up is $symbol${convertedMax.toStringAsFixed(convertedMax < 10 ? 2 : 0)}.';
    }

    if ((currentBalanceNgn + amountNgn) > balanceCapNgn) {
      final convertedCap = rates.convertFromNgn(balanceCapNgn, currency);
      return 'Top-up would exceed overall wallet balance limit of $symbol${convertedCap.toStringAsFixed(convertedCap < 10 ? 2 : 0)}.';
    }

    return null;
  }

  /// Evaluates whether a proposed P2P send amount satisfies single transaction
  /// floors and daily limits, accounting for currency conversion.
  Future<String?> validateP2pSend({
    required double amount,
    required String currency,
    required double todaySpentNgn,
    required String role,
    required bool isKycVerified,
  }) async {
    final limits = await fetchLimits();
    final rates = await exchangeRateService.fetchExchangeRates();

    final amountNgn = rates.convertToNgn(amount, currency);
    final minNgn = limits.minP2pTransferAmount;
    final dailyMaxNgn = limits.maxDailyP2pFor(
      role: role,
      isKycVerified: isKycVerified,
    );

    final symbol = ExchangeRates.symbolForCurrency(currency);

    if (amountNgn < minNgn) {
      final convertedMin = rates.convertFromNgn(minNgn, currency);
      return 'Minimum transfer amount is $symbol${convertedMin.toStringAsFixed(convertedMin < 10 ? 2 : 0)}.';
    }

    if ((todaySpentNgn + amountNgn) > dailyMaxNgn) {
      final remainingNgn = (dailyMaxNgn - todaySpentNgn).clamp(0.0, dailyMaxNgn);
      final convertedRemaining = rates.convertFromNgn(remainingNgn, currency);
      final convertedDailyMax = rates.convertFromNgn(dailyMaxNgn, currency);
      return 'Transfer exceeds daily P2P limit of $symbol${convertedDailyMax.toStringAsFixed(0)} ($symbol${convertedRemaining.toStringAsFixed(convertedRemaining < 10 ? 2 : 0)} remaining today).';
    }

    return null;
  }

  /// Evaluates whether a proposed withdrawal satisfies limits.
  Future<String?> validateWithdrawal({
    required double amount,
    required String currency,
    required double todayWithdrawnNgn,
    required String role,
    required bool isKycVerified,
  }) async {
    final limits = await fetchLimits();
    final rates = await exchangeRateService.fetchExchangeRates();

    final amountNgn = rates.convertToNgn(amount, currency);
    final minNgn = limits.minWithdrawalAmount;
    final dailyMaxNgn = limits.maxDailyWithdrawalFor(
      role: role,
      isKycVerified: isKycVerified,
    );

    final symbol = ExchangeRates.symbolForCurrency(currency);

    if (amountNgn < minNgn) {
      final convertedMin = rates.convertFromNgn(minNgn, currency);
      return 'Minimum withdrawal is $symbol${convertedMin.toStringAsFixed(convertedMin < 10 ? 2 : 0)}.';
    }

    if ((todayWithdrawnNgn + amountNgn) > dailyMaxNgn) {
      final remainingNgn = (dailyMaxNgn - todayWithdrawnNgn).clamp(0.0, dailyMaxNgn);
      final convertedRemaining = rates.convertFromNgn(remainingNgn, currency);
      final convertedDailyMax = rates.convertFromNgn(dailyMaxNgn, currency);
      return 'Withdrawal exceeds daily limit of $symbol${convertedDailyMax.toStringAsFixed(0)} ($symbol${convertedRemaining.toStringAsFixed(convertedRemaining < 10 ? 2 : 0)} remaining today).';
    }

    return null;
  }
}
