import 'package:cloud_firestore/cloud_firestore.dart';

/// Dynamic financial thresholds stored at `system_configs/financials`.
///
/// All values are editable in sese_hub without an app release. Clients and Cloud
/// Functions fall back to these compiled defaults when the document is missing/unreadable.
///
/// Configures platform driver credit requirements and referral commissions.
/// SESE operates with zero stored-value customer wallets, zero withdrawals,
/// and zero transfers.
class FinancialConfig {
  /// Minimum dispatch credit balance required for a driver to go ONLINE
  /// and receive dispatches. Default ₦1.00.
  /// Minimum Sese Credits required for a driver to go online and receive offers.
  final double minWalletBalanceToOnline;

  /// Alias for non-financial credit terminology.
  double get minCreditUnitsToOnline => minWalletBalanceToOnline;

  /// Minimum driver Sese Credits purchase amount. Default ₦1,000.00.
  final double minTopUpAmount;

  /// Standard referrers (customers & drivers) commission. Default 0.01 (1%).
  final double userReferralCommissionRate;

  /// Staff / agent / admin referrers commission. Default 0.02 (2%).
  final double agentReferralCommissionRate;

  /// Standard referral eligibility window in days. Default 365.
  final int standardReferralDurationDays;

  /// Agent referral eligibility window in days. Default 547 (~1.5 years).
  final int agentReferralDurationDays;

  const FinancialConfig({
    this.minWalletBalanceToOnline = 1.0,
    this.minTopUpAmount = 1000.0,
    this.userReferralCommissionRate = 0.01,
    this.agentReferralCommissionRate = 0.02,
    this.standardReferralDurationDays = 365,
    this.agentReferralDurationDays = 547,
  });

  factory FinancialConfig.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    double d(String k, double fb) =>
        (map![k] is num) ? (map[k] as num).toDouble() : fb;
    int i(String k, int fb) =>
        (map![k] is num) ? (map[k] as num).toInt() : fb;
    return FinancialConfig(
      minWalletBalanceToOnline: (map['minCreditUnitsToOnline'] is num)
          ? (map['minCreditUnitsToOnline'] as num).toDouble()
          : d('minWalletBalanceToOnline', 1.0),
      minTopUpAmount: d('minTopUpAmount', 1000.0),
      userReferralCommissionRate: d('userReferralCommissionRate', 0.01),
      agentReferralCommissionRate: d('agentReferralCommissionRate', 0.02),
      standardReferralDurationDays: i('standardReferralDurationDays', 365),
      agentReferralDurationDays: i('agentReferralDurationDays', 547),
    );
  }

  Map<String, dynamic> toMap() => {
        'minCreditUnitsToOnline': minWalletBalanceToOnline,
        'minWalletBalanceToOnline': minWalletBalanceToOnline,
        'minTopUpAmount': minTopUpAmount,
        'userReferralCommissionRate': userReferralCommissionRate,
        'agentReferralCommissionRate': agentReferralCommissionRate,
        'standardReferralDurationDays': standardReferralDurationDays,
        'agentReferralDurationDays': agentReferralDurationDays,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  FinancialConfig copyWith({
    double? minWalletBalanceToOnline,
    double? minTopUpAmount,
    double? userReferralCommissionRate,
    double? agentReferralCommissionRate,
    int? standardReferralDurationDays,
    int? agentReferralDurationDays,
  }) {
    return FinancialConfig(
      minWalletBalanceToOnline:
          minWalletBalanceToOnline ?? this.minWalletBalanceToOnline,
      minTopUpAmount: minTopUpAmount ?? this.minTopUpAmount,
      userReferralCommissionRate:
          userReferralCommissionRate ?? this.userReferralCommissionRate,
      agentReferralCommissionRate:
          agentReferralCommissionRate ?? this.agentReferralCommissionRate,
      standardReferralDurationDays:
          standardReferralDurationDays ?? this.standardReferralDurationDays,
      agentReferralDurationDays:
          agentReferralDurationDays ?? this.agentReferralDurationDays,
    );
  }
}

/// Field descriptors for the Hub Financial Settings form (label + help).
class FinancialFieldMeta {
  final String key;
  final String label;
  final String help;
  final bool isRate;
  final bool isInt;

  const FinancialFieldMeta({
    required this.key,
    required this.label,
    required this.help,
    this.isRate = false,
    this.isInt = false,
  });

  static const List<FinancialFieldMeta> all = [
    FinancialFieldMeta(
      key: 'minWalletBalanceToOnline',
      label: 'Min Sese Credits to go ONLINE (₦)',
      help: 'Driver must hold at least this balance in Sese Credits to receive orders.',
    ),
    FinancialFieldMeta(
      key: 'minTopUpAmount',
      label: 'Minimum Sese Credits Top-Up (₦)',
      help: 'Minimum credit purchase amount on Paystack.',
    ),
    FinancialFieldMeta(
      key: 'userReferralCommissionRate',
      label: 'User referral rate (0-1)',
      help: 'e.g. 0.01 = 1% per completed order for 365 days.',
      isRate: true,
    ),
    FinancialFieldMeta(
      key: 'agentReferralCommissionRate',
      label: 'Agent referral rate (0-1)',
      help: 'e.g. 0.02 = 2% per completed order for 547 days.',
      isRate: true,
    ),
    FinancialFieldMeta(
      key: 'standardReferralDurationDays',
      label: 'Standard window (days)',
      help: 'Commission eligibility for customers & drivers.',
      isInt: true,
    ),
    FinancialFieldMeta(
      key: 'agentReferralDurationDays',
      label: 'Agent window (days)',
      help: 'Commission eligibility for staff / agents / admins.',
      isInt: true,
    ),
  ];
}
