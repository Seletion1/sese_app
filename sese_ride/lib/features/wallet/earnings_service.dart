import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../payments/payment_service.dart';
import '../trips/models/trip_models.dart';

/// One completed trip's earnings for a driver.
class TripEarning {
  final String tripId;
  final double grossNaira;
  final double commissionNaira;
  final String serviceLabel;
  final String pickupAddress;
  final String dropoffAddress;
  final DateTime? completedAt;

  const TripEarning({
    required this.tripId,
    required this.grossNaira,
    required this.commissionNaira,
    this.serviceLabel = 'Ride',
    this.pickupAddress = '',
    this.dropoffAddress = '',
    this.completedAt,
  });

  double get netNaira => grossNaira - commissionNaira;

  factory TripEarning.fromTrip(ActiveTrip trip) {
    final commission = trip.commissionAmount > 0
        ? trip.commissionAmount
        : (trip.fareAmount * trip.commissionRate).abs();
    return TripEarning(
      tripId: trip.tripId,
      grossNaira: trip.fareAmount,
      commissionNaira: commission,
      serviceLabel:
          trip.serviceType == 'send_item' ? 'Courier' : 'Ride',
      pickupAddress: trip.pickupAddress,
      dropoffAddress: trip.dropoffAddress,
      completedAt: trip.completedAt ?? trip.earningDate,
    );
  }
}

/// One calendar day's totals.
class DayEarnings {
  final DateTime date;
  final double gross;
  final double commission;
  final double net;
  final int tripCount;

  const DayEarnings({
    required this.date,
    this.gross = 0,
    this.commission = 0,
    this.net = 0,
    this.tripCount = 0,
  });
}

/// Driver earnings data + pure period aggregation.
///
/// Completed trips come from `trips` (`driver.driverId` match, COMPLETED
/// filtered client-side so no composite index is required). Money math is
/// identical everywhere: gross = fare, commission = fare × rate on the
/// trip, net = gross − commission.
class EarningsService {
  final FirebaseFirestore? _firestore;

  EarningsService({this._firestore});

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Completed-trip earnings for [driverId], newest first.
  /// Merges nested `driver.driverId` and flat `driverId` Firestore queries
  /// so that every completed trip updates immediately with zero delay.
  Stream<List<TripEarning>> completedTripEarningsStream(String driverId,
      {int limit = 100}) {
    final db = _db;
    if (db == null || driverId.isEmpty) {
      return Stream.value(const <TripEarning>[]);
    }

    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? subNested;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? subFlat;
    List<QueryDocumentSnapshot<Map<String, dynamic>>> nestedDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> flatDocs = const [];

    late final StreamController<List<TripEarning>> controller;

    void emitCombined() {
      if (controller.isClosed) return;
      final map = <String, ActiveTrip>{};
      for (final doc in [...nestedDocs, ...flatDocs]) {
        try {
          final trip = ActiveTrip.fromMap(doc.id, doc.data());
          if (trip.status == TripStatus.completed) {
            map[trip.tripId] = trip;
          }
        } catch (_) {}
      }
      final items = map.values.map(TripEarning.fromTrip).toList()
        ..sort((a, b) => _compareEarningDate(b, a));
      controller.add(items.take(limit).toList());
    }

    controller = StreamController<List<TripEarning>>(
      onListen: () {
        subNested = db
            .collection('trips')
            .where('driver.driverId', isEqualTo: driverId)
            .snapshots()
            .listen(
              (snap) {
                nestedDocs = snap.docs;
                emitCombined();
              },
              onError: (err) => emitCombined(),
            );
        subFlat = db
            .collection('trips')
            .where('driverId', isEqualTo: driverId)
            .snapshots()
            .listen(
              (snap) {
                flatDocs = snap.docs;
                emitCombined();
              },
              onError: (err) => emitCombined(),
            );
      },
      onCancel: () {
        subNested?.cancel();
        subFlat?.cancel();
      },
    );

    return controller.stream;
  }

  /// Real-time stream of today's earnings totals for [driverId].
  /// Emits a new [DayEarnings] snapshot immediately whenever any completed trip updates.
  Stream<DayEarnings> todayEarningsStream(String driverId) {
    return completedTripEarningsStream(driverId).map((earnings) {
      final now = DateTime.now();
      return summarizeDay(earnings, now).day;
    });
  }

  static int _compareEarningDate(TripEarning a, TripEarning b) {
    final da = a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return da.compareTo(db);
  }

  static bool _sameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  /// Totals for a single calendar day + that day's trips (newest first).
  static ({DayEarnings day, List<TripEarning> trips}) summarizeDay(
      List<TripEarning> earnings, DateTime day) {
    final trips = earnings
        .where((e) => e.completedAt != null && _sameDay(e.completedAt!, day))
        .toList()
      ..sort((a, b) => _compareEarningDate(b, a));
    var gross = 0.0, commission = 0.0;
    for (final t in trips) {
      gross += t.grossNaira;
      commission += t.commissionNaira;
    }
    return (
      day: DayEarnings(
        date: DateTime(day.year, day.month, day.day),
        gross: gross,
        commission: commission,
        net: gross - commission,
        tripCount: trips.length,
      ),
      trips: trips,
    );
  }

  /// Monday→Sunday buckets for the week containing [anchor].
  static List<DayEarnings> summarizeWeek(
      List<TripEarning> earnings, DateTime anchor) {
    final monday =
        DateTime(anchor.year, anchor.month, anchor.day)
            .subtract(Duration(days: anchor.weekday - 1));
    return [
      for (var i = 0; i < 7; i++)
        summarizeDay(earnings, monday.add(Duration(days: i))).day,
    ];
  }

  /// High-level monthly totals.
  static DayEarnings summarizeMonth(
      List<TripEarning> earnings, int year, int month) {
    var gross = 0.0, commission = 0.0, count = 0;
    for (final e in earnings) {
      final d = e.completedAt?.toLocal();
      if (d == null || d.year != year || d.month != month) continue;
      gross += e.grossNaira;
      commission += e.commissionNaira;
      count++;
    }
    return DayEarnings(
      date: DateTime(year, month),
      gross: gross,
      commission: commission,
      net: gross - commission,
      tripCount: count,
    );
  }

  /// Referral/incentive wallet credits inside a month.
  static double summarizeMonthIncentives(
    List<WalletTransaction> transactions,
    int year,
    int month,
  ) {
    var total = 0.0;
    for (final t in transactions) {
      if (!WalletTransaction.isIncentiveType(t.type)) continue;
      final d = t.createdAt?.toLocal();
      if (d == null || d.year != year || d.month != month) continue;
      total += t.amountNaira;
    }
    return total;
  }
}
