import 'package:cloud_firestore/cloud_firestore.dart';

/// Dynamic financial thresholds stored at `system_configs/financials`.
///
/// All values are editable in sese_hub (Financial Settings tab) without an
/// app release. Clients and Cloud Functions fall back to these compiled
/// defaults when the document is missing/unreadable.
class FinancialConfig {
  /// Minimum withdrawable-cash balance required for a driver to go ONLINE
  /// and receive dispatches. Default ₦1.00.
  final double minWalletBalanceToOnline;

  /// Minimum wallet top-up / deposit amount. Default ₦1,300.00.
  final double minTopUpAmount;

  /// Standard referrers (customers & drivers) commission. Default 0.01 (1%).
  final double userReferralCommissionRate;

  /// Staff / agent / admin referrers commission. Default 0.02 (2%).
  final double agentReferralCommissionRate;

  /// Standard referral eligibility window in days. Default 365.
  final int standardReferralDurationDays;

  /// Agent referral eligibility window in days. Default 547 (~1.5 years).
  final int agentReferralDurationDays;

  /// Manual "Convert to Wallet" unlock threshold. Default ₦5,000.00.
  final double minConvertibleBonus;

  /// Auto-convert cap: entire seseCoinBalance moves to mainWalletBalance
  /// once reached. Default ₦10,000.00.
  final double maxBonusThreshold;

  /// Weekly payout-desk eligibility floor. Default ₦20,000.00.
  final double minPayoutThreshold;

  const FinancialConfig({
    this.minWalletBalanceToOnline = 1.0,
    this.minTopUpAmount = 1300.0,
    this.userReferralCommissionRate = 0.01,
    this.agentReferralCommissionRate = 0.02,
    this.standardReferralDurationDays = 365,
    this.agentReferralDurationDays = 547,
    this.minConvertibleBonus = 5000.0,
    this.maxBonusThreshold = 10000.0,
    this.minPayoutThreshold = 20000.0,
  });

  factory FinancialConfig.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    double d(String k, double fb) =>
        (map![k] is num) ? (map[k] as num).toDouble() : fb;
    int i(String k, int fb) =>
        (map![k] is num) ? (map[k] as num).toInt() : fb;
    return FinancialConfig(
      minWalletBalanceToOnline: d('minWalletBalanceToOnline', 1.0),
      minTopUpAmount: d('minTopUpAmount', 1300.0),
      userReferralCommissionRate: d('userReferralCommissionRate', 0.01),
      agentReferralCommissionRate: d('agentReferralCommissionRate', 0.02),
      standardReferralDurationDays: i('standardReferralDurationDays', 365),
      agentReferralDurationDays: i('agentReferralDurationDays', 547),
      minConvertibleBonus: d('minConvertibleBonus', 5000.0),
      maxBonusThreshold: d('maxBonusThreshold', 10000.0),
      minPayoutThreshold: d('minPayoutThreshold', 20000.0),
    );
  }

  Map<String, dynamic> toMap() => {
        'minWalletBalanceToOnline': minWalletBalanceToOnline,
        'minTopUpAmount': minTopUpAmount,
        'userReferralCommissionRate': userReferralCommissionRate,
        'agentReferralCommissionRate': agentReferralCommissionRate,
        'standardReferralDurationDays': standardReferralDurationDays,
        'agentReferralDurationDays': agentReferralDurationDays,
        'minConvertibleBonus': minConvertibleBonus,
        'maxBonusThreshold': maxBonusThreshold,
        'minPayoutThreshold': minPayoutThreshold,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  FinancialConfig copyWith({
    double? minWalletBalanceToOnline,
    double? minTopUpAmount,
    double? userReferralCommissionRate,
    double? agentReferralCommissionRate,
    int? standardReferralDurationDays,
    int? agentReferralDurationDays,
    double? minConvertibleBonus,
    double? maxBonusThreshold,
    double? minPayoutThreshold,
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
      minConvertibleBonus: minConvertibleBonus ?? this.minConvertibleBonus,
      maxBonusThreshold: maxBonusThreshold ?? this.maxBonusThreshold,
      minPayoutThreshold: minPayoutThreshold ?? this.minPayoutThreshold,
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
      label: 'Min wallet to go ONLINE (₦)',
      help: 'Driver must hold at least this in main wallet to receive orders.',
    ),
    FinancialFieldMeta(
      key: 'minTopUpAmount',
      label: 'Minimum top-up (₦)',
      help: 'Deposit CTA disabled below this amount.',
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
    FinancialFieldMeta(
      key: 'minConvertibleBonus',
      label: 'Min convertible bonus (₦)',
      help: '"Convert to Wallet" unlocks at this SeSe Coin balance.',
    ),
    FinancialFieldMeta(
      key: 'maxBonusThreshold',
      label: 'Auto-convert cap (₦)',
      help: 'Entire bonus auto-moves to cash wallet at this balance.',
    ),
    FinancialFieldMeta(
      key: 'minPayoutThreshold',
      label: 'Weekly payout floor (₦)',
      help: 'Payout Desk lists users at or above this cash balance.',
    ),
  ];
}
