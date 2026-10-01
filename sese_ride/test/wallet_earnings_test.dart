import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/payments/payment_service.dart';
import 'package:sese_ride/features/wallet/earnings_service.dart';
import 'package:sese_ride/features/wallet/earnings_screen.dart';
import 'package:sese_ride/features/wallet/wallet_screen.dart';

/// Canned wallet backend: balance + ledger + payouts, no Firebase.
class _FakePayments extends PaymentService {
  final int balanceKobo;
  final List<WalletTransaction> ledger;
  final List<DriverPayout> payouts;

  _FakePayments({
    this.balanceKobo = 250000,
    this.ledger = const [],
    this.payouts = const [],
  });

  @override
  Stream<int> walletBalanceKoboStream(String uid) =>
      Stream.value(balanceKobo);

  @override
  Stream<List<WalletTransaction>> walletHistoryStream(String uid,
          {int limit = 20}) =>
      Stream.value(ledger);

  @override
  Stream<List<DriverPayout>> driverPayoutsStream(String uid,
          {int limit = 10}) =>
      Stream.value(payouts);
}

class _FakeEarnings extends EarningsService {
  final List<TripEarning> trips;

  _FakeEarnings([this.trips = const []]);

  @override
  Stream<List<TripEarning>> completedTripEarningsStream(String driverId,
          {int limit = 100}) =>
      Stream.value(trips);
}

AppUser _driver() => AppUser(
      uid: 'driver_1',
      fullName: 'Test Driver',
      email: 'driver@test.co',
      phoneNumber: '08000000000',
      role: UserRole.driver,
      createdAt: DateTime(2024),
    );

WalletTransaction _tx(String id, String type, int kobo) =>
    WalletTransaction.fromMap(id, {
      'type': type,
      'amountKobo': kobo,
      'createdAt': '2026-09-25T10:00:00.000Z',
    });

void main() {
  group('WalletTransaction direction + labels', () {
    test('credits resolve positive with signed amounts', () {
      expect(_tx('a', 'wallet_topup', 250000).isCredit, isTrue);
      expect(_tx('a', 'wallet_topup', 250000).signedAmount, '+₦2,500.00');
      expect(_tx('b', 'trip_payment', 401000).isCredit, isTrue);
      expect(_tx('b', 'trip_payment', 401000)
          .displayLabel(driverView: true), 'Ride fare received');
      expect(_tx('c', 'streak_grand_award', 50000).isCredit, isTrue);
      expect(_tx('d', 'referral_bonus', 10000).signedAmount, '+₦100.00');
    });

    test('commission and withdrawal types resolve negative', () {
      expect(_tx('e', 'platform_commission', 35000).isCredit, isFalse);
      expect(_tx('e', 'platform_commission', 35000).label,
          'Platform commission fee');
      expect(
          _tx('e', 'platform_commission', 35000).signedAmount, '-₦350.00');
      expect(_tx('f', 'bank_withdrawal', 100000).isCredit, isFalse);
      expect(
          _tx('f', 'bank_withdrawal', 100000).label, 'Bank withdrawal');
    });

    test('incentive families are recognized', () {
      for (final t in [
        'streak_level2_cashback',
        'streak_level3_bonus',
        'streak_grand_award',
        'referral_bonus',
        'incentive_bonus'
      ]) {
        expect(WalletTransaction.isIncentiveType(t), isTrue);
      }
      expect(WalletTransaction.isIncentiveType('wallet_topup'), isFalse);
      expect(WalletTransaction.isIncentiveType('platform_commission'),
          isFalse);
    });
  });

  group('DriverPayout parsing', () {
    test('reads kobo, minor and naira shapes', () {
      expect(
          DriverPayout.fromMap('p1', {
            'amountKobo': 150000,
            'status': 'paid',
          }).amountNaira,
          1500.0);
      expect(
          DriverPayout.fromMap('p2', {
            'amount': 2500.0,
            'status': 'pending',
          }).amountNaira,
          2500.0);
      expect(
          DriverPayout.fromMap('p3', {'status': 'pending'}).amountNaira, 0.0);
    });
  });

  group('WalletScreen unified ledger', () {
    Future<void> pumpWallet(WidgetTester tester, _FakePayments payments,
        {void Function()? onEarnings}) async {
      await tester.pumpWidget(
        MaterialApp(home: WalletScreen(user: _driver(), payments: payments)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('balance card, both actions, signed ledger rows',
        (tester) async {
      await pumpWallet(
          tester,
          _FakePayments(balanceKobo: 250000, ledger: [
            _tx('t1', 'trip_payment', 401000),
            _tx('t2', 'platform_commission', 50000),
            _tx('t3', 'wallet_topup', 250000),
            _tx('t4', 'bank_withdrawal', 100000),
          ]));

      expect(find.text('Wallet & Earnings'), findsOneWidget);
      expect(find.text('₦2,500.00'), findsOneWidget);
      expect(find.text('+ Top Up'), findsOneWidget);
      expect(find.text('Withdraw / Payout'), findsOneWidget);
      expect(find.text('Ride fare received'), findsOneWidget);
      expect(find.text('+₦4,010.00'), findsOneWidget);
      expect(find.text('Platform commission fee'), findsOneWidget);
      expect(find.text('-₦500.00'), findsOneWidget);
      expect(find.text('Bank withdrawal'), findsOneWidget);
      expect(find.text('-₦1,000.00'), findsOneWidget);
      expect(find.text('Recent payouts'), findsOneWidget);
      expect(find.textContaining('No payouts yet'), findsOneWidget);
    });

    testWidgets('settled payouts render with status chips', (tester) async {
      await pumpWallet(
          tester,
          _FakePayments(payouts: [
            DriverPayout.fromMap('p1', {
              'amountKobo': 150000,
              'status': 'paid',
              'createdAt': '2026-09-20T10:00:00.000Z',
            }),
          ]));

      expect(find.text('₦1,500.00'), findsWidgets);
      expect(find.text('PAID'), findsOneWidget);
      expect(find.textContaining('No payouts yet'), findsNothing);
    });

    testWidgets('withdraw sheet opens the direct Paystack flow', (tester) async {
      await pumpWallet(tester, _FakePayments());

      await tester.tap(find.text('Withdraw / Payout'));
      await tester.pumpAndSettle();

      // New direct-withdrawal sheet (replaced "Request via Support"):
      // amount + bank + 10-digit account + verified-name + submit.
      expect(find.byKey(const Key('withdrawal_amount_field')),
          findsOneWidget);
      expect(
          find.byKey(const Key('withdrawal_bank_field')), findsOneWidget);
      expect(find.byKey(const Key('withdrawal_account_field')),
          findsOneWidget);
      expect(find.byKey(const Key('withdrawal_submit_button')),
          findsOneWidget);
      expect(find.text('Request via Support'), findsNothing);
    });

    testWidgets('wallet screen hosts no earnings breakdown card',
        (tester) async {
      await pumpWallet(tester, _FakePayments());

      expect(find.text('Earnings breakdown'), findsNothing);
      expect(find.text('Recent payouts'), findsOneWidget);
      expect(find.text('Transaction history'), findsOneWidget);
    });
  });

  group('EarningsScreen periods', () {
    List<TripEarning> cannedTrips() {
      final now = DateTime.now();
      final monday =
          DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: now.weekday - 1));
      // Keep the third trip inside BOTH the current week and month even
      // across a month boundary (the 1st is always in today's week then).
      // It must ALSO not land on today, or it contaminates the daily sum
      // (this broke every Monday and every 1st-of-month run: gross 9510
      // instead of 6510). Nudge forward within the same week when needed;
      // in the pathological Sunday-that-is-the-1st case there is no such
      // day, so fall back to Saturday (keeps the week green).
      DateTime thirdDay = monday.month == now.month
          ? monday.add(const Duration(hours: 10))
          : DateTime(now.year, now.month, 1, 10);
      final today =
          DateTime(now.year, now.month, now.day);
      if (thirdDay.year == today.year &&
          thirdDay.month == today.month &&
          thirdDay.day == today.day) {
        final nudged = thirdDay.add(const Duration(days: 1));
        thirdDay = (nudged.weekday == DateTime.monday ||
                nudged.month != now.month)
            ? thirdDay.subtract(const Duration(days: 2))
            : nudged;
      }
      return [
        TripEarning(
          tripId: 'today-1',
          grossNaira: 4010,
          commissionNaira: 501,
          completedAt: now,
        ),
        TripEarning(
          tripId: 'today-2',
          grossNaira: 2500,
          commissionNaira: 312,
          completedAt: now,
        ),
        TripEarning(
          tripId: 'mon-1',
          grossNaira: 3000,
          commissionNaira: 375,
          completedAt: thirdDay,
        ),
      ];
    }

    Future<void> pumpEarnings(
        WidgetTester tester, List<TripEarning> trips) async {
      await tester.pumpWidget(
        MaterialApp(
          home: EarningsScreen(
            user: _driver(),
            payments: _FakePayments(ledger: [
              WalletTransaction.fromMap('b1', {
                'type': 'streak_level3_bonus',
                'amountKobo': 20000,
                'createdAt': DateTime.now().toIso8601String(),
              }),
            ]),
            earnings: _FakeEarnings(trips),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('daily shows income, commission, net and trip rows',
        (tester) async {
      await pumpEarnings(tester, cannedTrips());

      expect(find.text("Today's fare income"), findsOneWidget);
      expect(find.text(PaymentService.formatNaira(6510)), findsOneWidget);
      expect(find.text(PaymentService.formatNaira(813)), findsOneWidget);
      expect(find.text(PaymentService.formatNaira(5697)), findsOneWidget);
      expect(find.text("Today's trips"), findsOneWidget);
    });

    testWidgets('weekly shows bars and totals', (tester) async {
      await pumpEarnings(tester, cannedTrips());

      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();
      expect(find.text('Gross fares — this week'), findsOneWidget);
      expect(find.text(PaymentService.formatNaira(9510)), findsOneWidget);
      expect(find.text('Mon'), findsOneWidget);
      expect(find.text('Sun'), findsOneWidget);
    });

    testWidgets('monthly rolls gross, fees, incentives and net',
        (tester) async {
      await pumpEarnings(tester, cannedTrips());

      await tester.tap(find.text('Monthly'));
      await tester.pumpAndSettle();
      expect(find.text('Total gross revenue'), findsOneWidget);
      expect(find.text('Total platform commissions'), findsOneWidget);
      expect(find.text('Referral / incentive earnings'), findsOneWidget);
      expect(find.textContaining('Final net earnings'), findsOneWidget);
      // Net = (9510 − 1188) + 200 bonus.
      expect(find.text(PaymentService.formatNaira(8522)), findsOneWidget);
    });
  });

  group('EarningsService aggregation', () {
    test('day/week/month buckets split correctly', () {
      final monday = DateTime(2026, 9, 21, 10);
      final trips = [
        TripEarning(
            tripId: 'a',
            grossNaira: 1000,
            commissionNaira: 100,
            completedAt: monday),
        TripEarning(
            tripId: 'b',
            grossNaira: 2000,
            commissionNaira: 300,
            completedAt: monday.add(const Duration(days: 2))),
        const TripEarning(tripId: 'c', grossNaira: 5000, commissionNaira: 0),
      ];

      final day = EarningsService.summarizeDay(trips, monday).day;
      expect(day.gross, 1000);
      expect(day.net, 900);
      expect(day.tripCount, 1);

      final week = EarningsService.summarizeWeek(
          trips, monday.add(const Duration(days: 6)));
      expect(week, hasLength(7));
      expect(week.map((d) => d.gross).reduce((a, b) => a + b), 3000);

      final month = EarningsService.summarizeMonth(trips, 2026, 9);
      expect(month.gross, 3000);
      expect(month.tripCount, 2);

      expect(
        EarningsService.summarizeMonthIncentives(
            [_tx('b1', 'streak_level3_bonus', 20000)], 2026, 9),
        200.0,
      );
    });
  });
}
