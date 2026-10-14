import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import 'earnings_service.dart';

enum EarningsPeriod { daily, weekly, monthly }

/// Structured earnings breakdown dashboard for drivers with
/// [Daily | Weekly | Monthly] filters.
///
/// - Daily: fare income, commission paid, net profit + trip breakdowns.
/// - Weekly: Mon–Sun bar chart of gross fares with commission/net totals.
/// - Monthly: gross revenue, commissions, referral/incentive earnings,
///   final net earnings.
///
/// Reads completed-trip settlement snapshots and wallet incentive credits;
/// all money math matches [EarningsService].
class EarningsScreen extends StatefulWidget {
  final AppUser user;

  /// Test seams.
  final PaymentService? payments;
  final EarningsService? earnings;

  const EarningsScreen({
    super.key,
    required this.user,
    this.payments,
    this.earnings,
  });

  @override
  State<EarningsScreen> createState() => EarningsScreenState();
}

class EarningsScreenState extends State<EarningsScreen> {
  EarningsPeriod _period = EarningsPeriod.daily;
  late final PaymentService _payments =
      widget.payments ?? PaymentService();
  late final EarningsService _earnings =
      widget.earnings ?? EarningsService();

  static const _labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SeseAppBar(title: 'Earnings'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<EarningsPeriod>(
              segments: const [
                ButtonSegment(
                    value: EarningsPeriod.daily, label: Text('Daily')),
                ButtonSegment(
                    value: EarningsPeriod.weekly, label: Text('Weekly')),
                ButtonSegment(
                    value: EarningsPeriod.monthly, label: Text('Monthly')),
              ],
              selected: {_period},
              onSelectionChanged: (s) =>
                  setState(() => _period = s.first),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<TripEarning>>(
              stream: _earnings
                  .completedTripEarningsStream(widget.user.uid),
              builder: (context, tripSnap) {
                return StreamBuilder<List<WalletTransaction>>(
                  stream: _payments.walletHistoryStream(widget.user.uid,
                      limit: 100),
                  builder: (context, walletSnap) {
                    final trips = tripSnap.data ?? const <TripEarning>[];
                    final wallet =
                        walletSnap.data ?? const <WalletTransaction>[];
                    switch (_period) {
                      case EarningsPeriod.daily:
                        return _DailyView(trips: trips);
                      case EarningsPeriod.weekly:
                        return _WeeklyView(trips: trips);
                      case EarningsPeriod.monthly:
                        return _MonthlyView(
                            trips: trips, wallet: wallet);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatCard(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: valueColor,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Daily: fare income, commission paid, net profit + trip breakdowns.
class _DailyView extends StatelessWidget {
  final List<TripEarning> trips;

  const _DailyView({required this.trips});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final summary = EarningsService.summarizeDay(trips, now);
    final day = summary.day;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: "Today's fare income",
                value: PaymentService.formatNaira(day.gross),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Commission paid',
                value: PaymentService.formatNaira(day.commission),
                valueColor: Colors.red.shade800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: "Today's net profit",
                value: PaymentService.formatNaira(day.net),
                valueColor: Colors.green.shade800,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Trips completed',
                value: '${day.tripCount}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          "Today's trips",
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        if (summary.trips.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.directions_car_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No trips completed today',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Go online to start receiving ride requests.',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          for (final t in summary.trips) _TripRow(earning: t),
      ],
    );
  }
}

class _TripRow extends StatelessWidget {
  final TripEarning earning;

  const _TripRow({required this.earning});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.green.shade50,
          child: Icon(Icons.check, color: Colors.green.shade800),
        ),
        title: Text(
          earning.pickupAddress.isEmpty
              ? earning.serviceLabel
              : '${earning.serviceLabel} • ${earning.pickupAddress}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          'Fare ${PaymentService.formatNaira(earning.grossNaira)} • '
          'Fee ${PaymentService.formatNaira(earning.commissionNaira)}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Text(
          '+${PaymentService.formatNaira(earning.netNaira)}',
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.green.shade800),
        ),
      ),
    );
  }
}

/// Weekly: Mon–Sun gross-fare bars + commission/net totals.
class _WeeklyView extends StatelessWidget {
  final List<TripEarning> trips;

  const _WeeklyView({required this.trips});

  @override
  Widget build(BuildContext context) {
    final days = EarningsService.summarizeWeek(trips, DateTime.now());
    var gross = 0.0, commission = 0.0;
    var count = 0;
    for (final d in days) {
      gross += d.gross;
      commission += d.commission;
      count += d.tripCount;
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Gross fares — this week',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _WeekBars(days: days),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    for (var i = 0; i < 7; i++)
                      Text(EarningsScreenState._labels[i],
                          style: const TextStyle(
                              fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Week gross',
                value: PaymentService.formatNaira(gross),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Commission',
                value: PaymentService.formatNaira(commission),
                valueColor: Colors.red.shade800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Week net',
                value: PaymentService.formatNaira(gross - commission),
                valueColor: Colors.green.shade800,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Trips',
                value: '$count',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Dependency-free 7-bar chart (net-green bars scaled to the max day).
class _WeekBars extends StatelessWidget {
  final List<DayEarnings> days;

  const _WeekBars({required this.days});

  @override
  Widget build(BuildContext context) {
    var max = 0.0;
    for (final d in days) {
      if (d.gross > max) max = d.gross;
    }
    if (max <= 0) max = 1;
    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final d in days)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message:
                      '${PaymentService.formatNaira(d.gross)} • ${d.tripCount} trips',
                  child: FractionallySizedBox(
                    heightFactor:
                        (d.gross / max).clamp(0.04, 1.0),
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      decoration: BoxDecoration(
                        color: d.gross > 0
                            ? Colors.green.shade600
                            : Colors.grey.shade300,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(6)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Monthly: gross, commissions, referral/incentive, final net.
class _MonthlyView extends StatelessWidget {
  final List<TripEarning> trips;
  final List<WalletTransaction> wallet;

  const _MonthlyView({required this.trips, required this.wallet});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final month =
        EarningsService.summarizeMonth(trips, now.year, now.month);
    final incentives = EarningsService.summarizeMonthIncentives(
        wallet, now.year, now.month);
    final net = month.net + incentives;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _MonthlyRow(
            label: 'Total gross revenue',
            value: PaymentService.formatNaira(month.gross)),
        _MonthlyRow(
          label: 'Total platform commissions',
          value: '-${PaymentService.formatNaira(month.commission)}',
          valueColor: Colors.red.shade800,
        ),
        _MonthlyRow(
          label: 'Referral / incentive earnings',
          value: '+${PaymentService.formatNaira(incentives)}',
          valueColor: Colors.green.shade800,
        ),
        const SizedBox(height: 12),
        _MonthlyRow(
          label: 'Final net earnings (${month.tripCount} trips)',
          value: PaymentService.formatNaira(net),
          valueColor: Colors.green.shade900,
          bold: true,
        ),
        const SizedBox(height: 8),
        const Text(
          'Commissions derive from each completed trip settlement; '
          'bonuses from wallet incentive credits.',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }
}

class _MonthlyRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  const _MonthlyRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontWeight:
                        bold ? FontWeight.bold : FontWeight.normal)),
          ),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: bold ? 18 : 15,
                  color: valueColor)),
        ],
      ),
    );
  }
}
