import 'package:cloud_firestore/cloud_firestore.dart';

/// Dynamic financial thresholds stored at `system_configs/financials`.
///
/// All values are editable in sese_hub (Financial Settings tab) without an
/// app release. Clients and Cloud Functions fall back to these compiled
/// defaults when the document is missing/unreadable.
///
/// Only contains parameters relevant to the unified wallet: commission
/// rates, minimum online balance, minimum withdrawal floor, referral
/// configuration, and minimum payout threshold.
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

  /// Weekly payout-desk eligibility floor. Default ₦20,000.00.
  final double minPayoutThreshold;

  /// Minimum withdrawal amount in Naira. Default ₦100.00.
  final double minWithdrawalNaira;

  /// Maximum wallet balance cap in Naira. Default ₦50,000.00.
  final double maxAccountBalance;

  /// Maximum single deposit / top-up in Naira. Default ₦20,000.00.
  final double maxSingleTopUp;

  /// Maximum top-up operations permitted per 24 hours. Default 5.
  final int dailyTopUpFrequency;

  /// Maximum cumulative withdrawal permitted per 24 hours in Naira. Default ₦20,000.00.
  final double maxDailyWithdrawal;

  const FinancialConfig({
    this.minWalletBalanceToOnline = 1.0,
    this.minTopUpAmount = 1300.0,
    this.userReferralCommissionRate = 0.01,
    this.agentReferralCommissionRate = 0.02,
    this.standardReferralDurationDays = 365,
    this.agentReferralDurationDays = 547,
    this.minPayoutThreshold = 20000.0,
    this.minWithdrawalNaira = 100.0,
    this.maxAccountBalance = 50000.0,
    this.maxSingleTopUp = 20000.0,
    this.dailyTopUpFrequency = 5,
    this.maxDailyWithdrawal = 20000.0,
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
      minPayoutThreshold: d('minPayoutThreshold', 20000.0),
      minWithdrawalNaira: d('minWithdrawalNaira', 100.0),
      maxAccountBalance: d('maxAccountBalance', 50000.0),
      maxSingleTopUp: d('maxSingleTopUp', 20000.0),
      dailyTopUpFrequency: i('dailyTopUpFrequency', 5),
      maxDailyWithdrawal: d('maxDailyWithdrawal', 20000.0),
    );
  }

  Map<String, dynamic> toMap() => {
        'minWalletBalanceToOnline': minWalletBalanceToOnline,
        'minTopUpAmount': minTopUpAmount,
        'userReferralCommissionRate': userReferralCommissionRate,
        'agentReferralCommissionRate': agentReferralCommissionRate,
        'standardReferralDurationDays': standardReferralDurationDays,
        'agentReferralDurationDays': agentReferralDurationDays,
        'minPayoutThreshold': minPayoutThreshold,
        'minWithdrawalNaira': minWithdrawalNaira,
        'maxAccountBalance': maxAccountBalance,
        'maxSingleTopUp': maxSingleTopUp,
        'dailyTopUpFrequency': dailyTopUpFrequency,
        'maxDailyWithdrawal': maxDailyWithdrawal,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  FinancialConfig copyWith({
    double? minWalletBalanceToOnline,
    double? minTopUpAmount,
    double? userReferralCommissionRate,
    double? agentReferralCommissionRate,
    int? standardReferralDurationDays,
    int? agentReferralDurationDays,
    double? minPayoutThreshold,
    double? minWithdrawalNaira,
    double? maxAccountBalance,
    double? maxSingleTopUp,
    int? dailyTopUpFrequency,
    double? maxDailyWithdrawal,
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
      minPayoutThreshold: minPayoutThreshold ?? this.minPayoutThreshold,
      minWithdrawalNaira: minWithdrawalNaira ?? this.minWithdrawalNaira,
      maxAccountBalance: maxAccountBalance ?? this.maxAccountBalance,
      maxSingleTopUp: maxSingleTopUp ?? this.maxSingleTopUp,
      dailyTopUpFrequency: dailyTopUpFrequency ?? this.dailyTopUpFrequency,
      maxDailyWithdrawal: maxDailyWithdrawal ?? this.maxDailyWithdrawal,
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
      key: 'minPayoutThreshold',
      label: 'Weekly payout floor (₦)',
      help: 'Payout Desk lists users at or above this cash balance.',
    ),
    FinancialFieldMeta(
      key: 'minWithdrawalNaira',
      label: 'Minimum withdrawal (₦)',
      help: 'Withdrawal rejected below this amount.',
    ),
    FinancialFieldMeta(
      key: 'maxAccountBalance',
      label: 'Max Account Balance (₦)',
      help: 'Maximum wallet balance cap.',
    ),
    FinancialFieldMeta(
      key: 'maxSingleTopUp',
      label: 'Max Single Top-Up (₦)',
      help: 'Single deposit ceiling.',
    ),
    FinancialFieldMeta(
      key: 'dailyTopUpFrequency',
      label: 'Daily Top-Up Frequency',
      help: 'Max top-up transactions permitted per day.',
      isInt: true,
    ),
    FinancialFieldMeta(
      key: 'maxDailyWithdrawal',
      label: 'Max Daily Withdrawal (₦)',
      help: 'Maximum withdrawal permitted per day.',
    ),
  ];
}
