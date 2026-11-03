import 'package:cloud_firestore/cloud_firestore.dart';

/// Dynamic, server-enforced financial limits configuration stored at
/// `/system_config/financial_limits`.
///
/// Configures role-based limits (Customer, Driver, Hub Admin) and KYC tiered
/// thresholds for single-transaction top-up caps, daily transaction volume,
/// daily top-up frequency, and overall wallet balance caps.
class FinancialLimitsConfig {
  // ── Customer Limits ────────────────────────────────────────────────────────
  final double customerMinTopUp;
  final double customerMaxSingleTopUp;
  final int customerMaxDailyTopUpCount;
  final double customerMaxWalletBalanceUnverified;
  final double customerMaxWalletBalanceVerified;
  final double customerMaxDailyP2pUnverified;
  final double customerMaxDailyP2pVerified;
  final double customerMaxDailyWithdrawalUnverified;
  final double customerMaxDailyWithdrawalVerified;

  // ── Driver Limits ──────────────────────────────────────────────────────────
  final double driverMinTopUp;
  final double driverMaxSingleTopUp;
  final int driverMaxDailyTopUpCount;
  final double driverMaxWalletBalanceUnverified;
  final double driverMaxWalletBalanceVerified;
  final double driverMaxDailyP2pUnverified;
  final double driverMaxDailyP2pVerified;
  final double driverMaxDailyWithdrawalUnverified;
  final double driverMaxDailyWithdrawalVerified;

  // ── Hub Admin / Staff Limits ───────────────────────────────────────────────
  final double hubAdminMinTopUp;
  final double hubAdminMaxSingleTopUp;
  final int hubAdminMaxDailyTopUpCount;
  final double hubAdminMaxWalletBalance;
  final double hubAdminMaxDailyP2p;
  final double hubAdminMaxDailyWithdrawal;

  // ── General Transaction Floored Minimums ───────────────────────────────────
  final double minWithdrawalAmount;
  final double minP2pTransferAmount;

  const FinancialLimitsConfig({
    // Customer defaults
    this.customerMinTopUp = 100.0,
    this.customerMaxSingleTopUp = 20000.0,
    this.customerMaxDailyTopUpCount = 5,
    this.customerMaxWalletBalanceUnverified = 20000.0,
    this.customerMaxWalletBalanceVerified = 50000.0,
    this.customerMaxDailyP2pUnverified = 5000.0,
    this.customerMaxDailyP2pVerified = 15000.0,
    this.customerMaxDailyWithdrawalUnverified = 10000.0,
    this.customerMaxDailyWithdrawalVerified = 25000.0,

    // Driver defaults
    this.driverMinTopUp = 100.0,
    this.driverMaxSingleTopUp = 20000.0,
    this.driverMaxDailyTopUpCount = 5,
    this.driverMaxWalletBalanceUnverified = 20000.0,
    this.driverMaxWalletBalanceVerified = 50000.0,
    this.driverMaxDailyP2pUnverified = 5000.0,
    this.driverMaxDailyP2pVerified = 15000.0,
    this.driverMaxDailyWithdrawalUnverified = 15000.0,
    this.driverMaxDailyWithdrawalVerified = 35000.0,

    // Hub Admin defaults
    this.hubAdminMinTopUp = 100.0,
    this.hubAdminMaxSingleTopUp = 50000.0,
    this.hubAdminMaxDailyTopUpCount = 15,
    this.hubAdminMaxWalletBalance = 50000.0,
    this.hubAdminMaxDailyP2p = 10000.0,
    this.hubAdminMaxDailyWithdrawal = 20000.0,

    // General transaction minimums
    this.minWithdrawalAmount = 100.0,
    this.minP2pTransferAmount = 100.0,
  });

  factory FinancialLimitsConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) return const FinancialLimitsConfig();

    double d(String k, double fallback) {
      final v = map[k];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? fallback;
      return fallback;
    }

    int i(String k, int fallback) {
      final v = map[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    return FinancialLimitsConfig(
      customerMinTopUp: d('customerMinTopUp', 100.0),
      customerMaxSingleTopUp: d('customerMaxSingleTopUp', 20000.0),
      customerMaxDailyTopUpCount: i('customerMaxDailyTopUpCount', 5),
      customerMaxWalletBalanceUnverified: d('customerMaxWalletBalanceUnverified', 20000.0),
      customerMaxWalletBalanceVerified: d('customerMaxWalletBalanceVerified', 50000.0),
      customerMaxDailyP2pUnverified: d('customerMaxDailyP2pUnverified', 5000.0),
      customerMaxDailyP2pVerified: d('customerMaxDailyP2pVerified', 15000.0),
      customerMaxDailyWithdrawalUnverified: d('customerMaxDailyWithdrawalUnverified', 10000.0),
      customerMaxDailyWithdrawalVerified: d('customerMaxDailyWithdrawalVerified', 25000.0),

      driverMinTopUp: d('driverMinTopUp', 100.0),
      driverMaxSingleTopUp: d('driverMaxSingleTopUp', 20000.0),
      driverMaxDailyTopUpCount: i('driverMaxDailyTopUpCount', 5),
      driverMaxWalletBalanceUnverified: d('driverMaxWalletBalanceUnverified', 20000.0),
      driverMaxWalletBalanceVerified: d('driverMaxWalletBalanceVerified', 50000.0),
      driverMaxDailyP2pUnverified: d('driverMaxDailyP2pUnverified', 5000.0),
      driverMaxDailyP2pVerified: d('driverMaxDailyP2pVerified', 15000.0),
      driverMaxDailyWithdrawalUnverified: d('driverMaxDailyWithdrawalUnverified', 15000.0),
      driverMaxDailyWithdrawalVerified: d('driverMaxDailyWithdrawalVerified', 35000.0),

      hubAdminMinTopUp: d('hubAdminMinTopUp', 100.0),
      hubAdminMaxSingleTopUp: d('hubAdminMaxSingleTopUp', 50000.0),
      hubAdminMaxDailyTopUpCount: i('hubAdminMaxDailyTopUpCount', 15),
      hubAdminMaxWalletBalance: d('hubAdminMaxWalletBalance', 50000.0),
      hubAdminMaxDailyP2p: d('hubAdminMaxDailyP2p', 10000.0),
      hubAdminMaxDailyWithdrawal: d('hubAdminMaxDailyWithdrawal', 20000.0),

      minWithdrawalAmount: d('minWithdrawalAmount', 100.0),
      minP2pTransferAmount: d('minP2pTransferAmount', 100.0),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'customerMinTopUp': customerMinTopUp,
      'customerMaxSingleTopUp': customerMaxSingleTopUp,
      'customerMaxDailyTopUpCount': customerMaxDailyTopUpCount,
      'customerMaxWalletBalanceUnverified': customerMaxWalletBalanceUnverified,
      'customerMaxWalletBalanceVerified': customerMaxWalletBalanceVerified,
      'customerMaxDailyP2pUnverified': customerMaxDailyP2pUnverified,
      'customerMaxDailyP2pVerified': customerMaxDailyP2pVerified,
      'customerMaxDailyWithdrawalUnverified': customerMaxDailyWithdrawalUnverified,
      'customerMaxDailyWithdrawalVerified': customerMaxDailyWithdrawalVerified,

      'driverMinTopUp': driverMinTopUp,
      'driverMaxSingleTopUp': driverMaxSingleTopUp,
      'driverMaxDailyTopUpCount': driverMaxDailyTopUpCount,
      'driverMaxWalletBalanceUnverified': driverMaxWalletBalanceUnverified,
      'driverMaxWalletBalanceVerified': driverMaxWalletBalanceVerified,
      'driverMaxDailyP2pUnverified': driverMaxDailyP2pUnverified,
      'driverMaxDailyP2pVerified': driverMaxDailyP2pVerified,
      'driverMaxDailyWithdrawalUnverified': driverMaxDailyWithdrawalUnverified,
      'driverMaxDailyWithdrawalVerified': driverMaxDailyWithdrawalVerified,

      'hubAdminMinTopUp': hubAdminMinTopUp,
      'hubAdminMaxSingleTopUp': hubAdminMaxSingleTopUp,
      'hubAdminMaxDailyTopUpCount': hubAdminMaxDailyTopUpCount,
      'hubAdminMaxWalletBalance': hubAdminMaxWalletBalance,
      'hubAdminMaxDailyP2p': hubAdminMaxDailyP2p,
      'hubAdminMaxDailyWithdrawal': hubAdminMaxDailyWithdrawal,

      'minWithdrawalAmount': minWithdrawalAmount,
      'minP2pTransferAmount': minP2pTransferAmount,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  /// Resolves the maximum wallet balance cap in Naira for a given role and KYC state.
  double maxWalletBalanceFor({required String role, required bool isKycVerified}) {
    switch (role.toLowerCase()) {
      case 'driver':
        return isKycVerified
            ? driverMaxWalletBalanceVerified
            : driverMaxWalletBalanceUnverified;
      case 'hub_admin':
      case 'admin':
      case 'operations_admin':
      case 'super_admin':
        return hubAdminMaxWalletBalance;
      case 'customer':
      default:
        return isKycVerified
            ? customerMaxWalletBalanceVerified
            : customerMaxWalletBalanceUnverified;
    }
  }

  /// Resolves the single top-up ceiling in Naira for a role.
  double maxSingleTopUpFor(String role) {
    switch (role.toLowerCase()) {
      case 'driver':
        return driverMaxSingleTopUp;
      case 'hub_admin':
      case 'admin':
      case 'operations_admin':
      case 'super_admin':
        return hubAdminMaxSingleTopUp;
      case 'customer':
      default:
        return customerMaxSingleTopUp;
    }
  }

  /// Resolves the minimum top-up floor in Naira for a role.
  double minTopUpFor(String role) {
    switch (role.toLowerCase()) {
      case 'driver':
        return driverMinTopUp;
      case 'hub_admin':
      case 'admin':
      case 'operations_admin':
      case 'super_admin':
        return hubAdminMinTopUp;
      case 'customer':
      default:
        return customerMinTopUp;
    }
  }

  /// Resolves the daily P2P send maximum in Naira for a role and KYC state.
  double maxDailyP2pFor({required String role, required bool isKycVerified}) {
    switch (role.toLowerCase()) {
      case 'driver':
        return isKycVerified
            ? driverMaxDailyP2pVerified
            : driverMaxDailyP2pUnverified;
      case 'hub_admin':
      case 'admin':
      case 'operations_admin':
      case 'super_admin':
        return hubAdminMaxDailyP2p;
      case 'customer':
      default:
        return isKycVerified
            ? customerMaxDailyP2pVerified
            : customerMaxDailyP2pUnverified;
    }
  }

  /// Resolves the daily withdrawal maximum in Naira for a role and KYC state.
  double maxDailyWithdrawalFor({required String role, required bool isKycVerified}) {
    switch (role.toLowerCase()) {
      case 'driver':
        return isKycVerified
            ? driverMaxDailyWithdrawalVerified
            : driverMaxDailyWithdrawalUnverified;
      case 'hub_admin':
      case 'admin':
      case 'operations_admin':
      case 'super_admin':
        return hubAdminMaxDailyWithdrawal;
      case 'customer':
      default:
        return isKycVerified
            ? customerMaxDailyWithdrawalVerified
            : customerMaxDailyWithdrawalUnverified;
    }
  }

  /// Resolves the daily top-up attempt frequency cap for a role.
  int maxDailyTopUpCountFor(String role) {
    switch (role.toLowerCase()) {
      case 'driver':
        return driverMaxDailyTopUpCount;
      case 'hub_admin':
      case 'admin':
      case 'operations_admin':
      case 'super_admin':
        return hubAdminMaxDailyTopUpCount;
      case 'customer':
      default:
        return customerMaxDailyTopUpCount;
    }
  }
}
