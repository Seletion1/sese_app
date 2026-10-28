import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../models/bid_models.dart';
import '../models/trip_models.dart';

/// Thrown when trip creation / cancellation fails. Always carries a
/// [userMessage] safe to show in a SnackBar.
class TripException implements Exception {
  final String code;
  final String userMessage;

  const TripException(this.code, this.userMessage);

  @override
  String toString() => 'TripException($code): $userMessage';
}

/// Live-dispatch data seam.
///
/// Production path is fully server-driven: `createTrip` mints the
/// `trips/{tripId}` document (status `SEARCHING_DRIVER`), Cloud Functions
/// own matchmaking / ping timeouts / re-broadcasts, and the client only
/// listens. Tests inject a fake — never Firebase.
abstract class TripRepository {
  /// Creates the trip via the `createTrip` callable. Returns the tripId.
  Future<String> createTrip(TripDraft draft);

  /// Live snapshot stream for one trip (null while the doc is missing).
  Stream<ActiveTrip?> tripStream(String tripId);

  /// All live (non-terminal) trips for a customer — powers the Trips tab
  /// and re-entry restore after the app was closed.
  Stream<List<ActiveTrip>> activeTripsStream(String customerId);

  /// Real-time stream of all trip events (active, completed, cancelled) for a customer or driver,
  /// ordered newest-first.
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false});

  /// Customer cancellation (server transitions to CANCELLED).
  ///
  /// [reason] is a [CancelTripDialog] reason code, audited server-side into
  /// the immutable `cancellation_audits` collection and counted toward the
  /// hourly spam-cancel rate limit. Null/unknown codes land as `other`.
  Future<void> cancelTrip(String tripId, {String? reason});

  // ── Bidding API ────────────────────────────────────────────────────────────

  /// Driver submits a custom-fare bid. [offeredFare] must be ≥ baseline.
  Future<void> submitBid(
    String tripId,
    double offeredFare, {
    int? etaMinutes,
  });

  /// Customer rejects a driver's pending bid.
  Future<void> rejectBid(String tripId, String driverId);

  /// Customer atomically accepts one bid (server rejects all others).
  Future<void> acceptBid(String tripId, String driverId);

  /// Customer raises the fare above the current amount.
  /// When the trip was in [TripStatus.needsCustomerAction] the backend
  /// resets it to [TripStatus.searchingDriver] and restarts dispatch.
  Future<void> increaseTripFare(String tripId, double newFare);

  /// Live stream of all bids on a trip, ordered newest-first.
  /// Only pending bids are relevant for the carousel; accepted/rejected
  /// are included so the UI can reflect outcomes in real time.
  Stream<List<BidModel>> bidsStream(String tripId);
}

/// Production transport: `createTrip` callable + Firestore snapshots.
class FirestoreTripRepository implements TripRepository {
  // Lazy getters so merely constructing the repo (e.g. as a widget default)
  // never touches Firebase — only actual calls do.
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _fn => FirebaseFunctions.instance;

  @override
  Future<String> createTrip(TripDraft draft) async {
    try {
      final result =
          await _fn.httpsCallable('createTrip').call(draft.toMap());
      final data = Map<String, dynamic>.from(result.data as Map);
      final tripId = (data['tripId'] ?? '').toString();
      if (tripId.isEmpty) {
        throw const TripException(
          'invalid-response',
          'The server did not return a trip. Please try again.',
        );
      }
      if (kDebugMode) debugPrint('TripRepository: created trip $tripId');
      return tripId;
    } on FirebaseFunctionsException catch (e) {
      debugPrint('TripRepository.createTrip ${e.code}: ${e.message}');
      throw TripException(e.code, _mapError(e.code, e.message));
    } catch (e) {
      debugPrint('TripRepository.createTrip error: $e');
      if (e is TripException) rethrow;
      throw const TripException(
        'network-error',
        'Could not reach the dispatch server. Check your connection and try again.',
      );
    }
  }

  @override
  Stream<ActiveTrip?> tripStream(String tripId) {
    return _db.collection('trips').doc(tripId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ActiveTrip.fromMap(doc.id, doc.data() ?? {});
    });
  }

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) {
    if (customerId.isEmpty) return Stream.value(const []);
    // Single-field query on purpose: no composite index required.
    // Terminal states are filtered client-side via [ActiveTrip.isLive].
    return _db
        .collection('trips')
        .where('customerId', isEqualTo: customerId)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ActiveTrip.fromMap(d.id, d.data()))
            .where((t) => t.isLive)
            .toList());
  }

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(
    String userId, {
    bool isDriver = false,
  }) {
    if (userId.isEmpty) return Stream.value(const []);
    try {
      if (!isDriver) {
        // Customer history query: all historical trips booked by customerId
        return _db
            .collection('trips')
            .where('customerId', isEqualTo: userId)
            .snapshots()
            .map((snap) {
          final list = snap.docs
              .map((d) => ActiveTrip.fromMap(d.id, d.data()))
              .toList();
          list.sort((a, b) => _compareTripDate(b, a));
          return list;
        }).handleError((e) {
          debugPrint('userTripHistoryStream (customer) error: $e');
          return const <ActiveTrip>[];
        });
      }

      // Driver lifetime history: queries all historical trips where driver is
      // assigned via `driver.driverId` or legacy flat `driverId`.
      // NO date restriction (e.g. today/00:00:00) so drivers see complete lifetime
      // history across all statuses (completed, accepted, in-progress, cancelled, rejected).
      late final StreamController<List<ActiveTrip>> controller;
      StreamSubscription? subNested;
      StreamSubscription? subFlat;

      List<QueryDocumentSnapshot<Map<String, dynamic>>> nestedDocs = [];
      List<QueryDocumentSnapshot<Map<String, dynamic>>> flatDocs = [];

      void emitCombined() {
        if (controller.isClosed) return;
        final map = <String, ActiveTrip>{};
        for (final doc in [...nestedDocs, ...flatDocs]) {
          try {
            final trip = ActiveTrip.fromMap(doc.id, doc.data());
            map[trip.tripId] = trip;
          } catch (e) {
            debugPrint('Error parsing trip doc ${doc.id}: $e');
          }
        }
        final list = map.values.toList();
        list.sort((a, b) => _compareTripDate(b, a));
        controller.add(list);
      }

      controller = StreamController<List<ActiveTrip>>(
        onListen: () {
          try {
            subNested = _db
                .collection('trips')
                .where('driver.driverId', isEqualTo: userId)
                .snapshots()
                .listen(
              (snap) {
                nestedDocs = snap.docs;
                emitCombined();
              },
              onError: (err) {
                debugPrint('userTripHistoryStream (driver.driverId) error: $err');
                emitCombined();
              },
            );

            subFlat = _db
                .collection('trips')
                .where('driverId', isEqualTo: userId)
                .snapshots()
                .listen(
              (snap) {
                flatDocs = snap.docs;
                emitCombined();
              },
              onError: (err) {
                debugPrint('userTripHistoryStream (driverId) error: $err');
                emitCombined();
              },
            );
          } catch (e) {
            debugPrint('userTripHistoryStream listener error: $e');
            emitCombined();
          }
        },
        onCancel: () {
          subNested?.cancel();
          subFlat?.cancel();
        },
      );

      return controller.stream;
    } catch (e) {
      debugPrint('FirestoreTripRepository.userTripHistoryStream error: $e');
      return Stream.value(const []);
    }
  }

  static int _compareTripDate(ActiveTrip a, ActiveTrip b) {
    final da = a.createdAt ?? a.updatedAt ?? a.settledAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = b.createdAt ?? b.updatedAt ?? b.settledAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return db.compareTo(da);
  }

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {
    try {
      await _fn.httpsCallable('cancelTrip').call({
        'tripId': tripId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        if (useCashSettlement) 'useCashSettlement': true,
      });
    } on FirebaseFunctionsException catch (e) {
      throw TripException(e.code, _mapError(e.code, e.message));
    }
  }

  // ── Bidding ────────────────────────────────────────────────────────────────

  @override
  Future<void> submitBid(
    String tripId,
    double offeredFare, {
    int? etaMinutes,
  }) async {
    try {
      final payload = <String, dynamic>{
        'tripId': tripId,
        'offeredFare': offeredFare,
      };
      if (etaMinutes != null) payload['etaMinutes'] = etaMinutes;
      await _fn.httpsCallable('submitBid').call(payload);
    } on FirebaseFunctionsException catch (e) {
      throw TripException(e.code, _mapError(e.code, e.message));
    }
  }

  @override
  Future<void> rejectBid(String tripId, String driverId) async {
    try {
      await _fn.httpsCallable('rejectBid').call({
        'tripId': tripId,
        'driverId': driverId,
      });
    } on FirebaseFunctionsException catch (e) {
      throw TripException(e.code, _mapError(e.code, e.message));
    }
  }

  @override
  Future<void> acceptBid(String tripId, String driverId) async {
    try {
      await _fn.httpsCallable('acceptBid').call({
        'tripId': tripId,
        'driverId': driverId,
      });
    } on FirebaseFunctionsException catch (e) {
      throw TripException(e.code, _mapError(e.code, e.message));
    }
  }

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {
    try {
      await _fn.httpsCallable('increaseTripFare').call({
        'tripId': tripId,
        'newFare': newFare,
      });
    } on FirebaseFunctionsException catch (e) {
      throw TripException(e.code, _mapError(e.code, e.message));
    }
  }

  @override
  Stream<List<BidModel>> bidsStream(String tripId) {
    return _db
        .collection('trips')
        .doc(tripId)
        .collection('bids')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => BidModel.fromMap(d.id, d.data()))
            .toList());
  }

  static String _mapError(String code, String? message) {
    switch (code) {
      case 'unauthenticated':
        return 'Your session has expired. Please sign in again.';
      case 'invalid-argument':
        return message ?? 'Invalid trip details. Please review and try again.';
      case 'not-found':
        return 'Trip not found. It may have been cancelled.';
      case 'failed-precondition':
        return message ?? 'This trip can no longer be changed.';
      default:
        return message ?? 'Dispatch failed. Please try again.';
    }
  }
}
