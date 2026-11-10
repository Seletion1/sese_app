import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false});

  /// Driver confirms cash collected from customer for waiting time cancellation.
  Future<void> confirmCashCancellation(String tripId) async {}

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

  /// Customer reassigns/retries an expired or stuck trip.
  /// Instantly retries the dispatch sequence from the beginning (re-running the
  /// 1st -> 2nd -> 3rd nearest driver loop followed by the public order pool).
  ///
  /// Optionally accepts an updated `newFare` parameter for one-tap fare boost chips.
  Future<void> reassignTrip(String tripId, {double? newFare});

  /// Customer requests to continue searching after auto-reassignment threshold is reached.
  Future<void> keepSearchingTrip(String tripId);

  /// Live stream of all bids on a trip, ordered newest-first.
  /// Only pending bids are relevant for the carousel; accepted/rejected
  /// are included so the UI can reflect outcomes in real time.
  Stream<List<BidModel>> bidsStream(String tripId);

  /// Stream of active unexpired pending bid for a driver across all trips, if any.
  Stream<BidModel?> activeDriverBidStream(String driverId);

  /// Direct real-time stream of a driver's specific bid on a given trip.
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) =>
      Stream.value(null);
}

/// Production transport: `createTrip` callable + Firestore snapshots.
class FirestoreTripRepository implements TripRepository {
  // Lazy getters so merely constructing the repo (e.g. as a widget default)
  // never touches Firebase — only actual calls do.
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _fn => FirebaseFunctions.instance;

  @override
  Future<String> createTrip(TripDraft draft) async {
    return _callWithAuthRetry(() async {
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
    });
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
    // Terminal and cancelled states are filtered client-side via [ActiveTrip.isCustomerLive].
    return _db
        .collection('trips')
        .where('customerId', isEqualTo: customerId)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ActiveTrip.fromMap(d.id, d.data()))
            .where((t) => t.isCustomerLive)
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
        // Customer history query: all historical trips booked by customerId.
        // Excludes trips fulfilled by this user as a driver.
        return _db
            .collection('trips')
            .where('customerId', isEqualTo: userId)
            .snapshots()
            .map((snap) {
          final list = snap.docs
              .map((d) => ActiveTrip.fromMap(d.id, d.data()))
              .where((trip) =>
                  trip.customerId == userId &&
                  trip.driver?.driverId != userId &&
                  trip.driverId != userId)
              .toList();
          list.sort((a, b) => _compareTripDate(a, b));
          return list;
        }).handleError((e) {
          debugPrint('userTripHistoryStream (customer) error: $e');
          return const <ActiveTrip>[];
        });
      }

      // Driver lifetime history: queries historical trips where user was assigned
      // or attempted as driver. Excludes customer-booked trips created by this user
      // and completed trips fulfilled by other drivers.
      late final StreamController<List<ActiveTrip>> controller;
      StreamSubscription? subNested;
      StreamSubscription? subFlat;
      StreamSubscription? subAttempted;

      List<QueryDocumentSnapshot<Map<String, dynamic>>> nestedDocs = [];
      List<QueryDocumentSnapshot<Map<String, dynamic>>> flatDocs = [];
      List<QueryDocumentSnapshot<Map<String, dynamic>>> attemptedDocs = [];

      void emitCombined() {
        if (controller.isClosed) return;
        final map = <String, ActiveTrip>{};
        for (final doc in [...nestedDocs, ...flatDocs, ...attemptedDocs]) {
          try {
            final trip = ActiveTrip.fromMap(doc.id, doc.data());

            // 1. Customer-booked trips created by this user MUST NOT leak
            // into driver history.
            if (trip.customerId == userId) continue;

            // 2. Completed trips must be fulfilled by this driver, not another.
            final isAssignedDriver =
                trip.driver?.driverId == userId || trip.driverId == userId;

            if (trip.status == TripStatus.completed && !isAssignedDriver) {
              continue;
            }

            final existing = map[trip.tripId];
            if (existing != null) {
              // Deduplication & state superseding:
              // 1. Terminal completed state strictly supersedes any earlier skipped or open snapshot.
              if (existing.status == TripStatus.completed &&
                  trip.status != TripStatus.completed) {
                continue;
              }
              if (trip.status == TripStatus.completed &&
                  existing.status != TripStatus.completed) {
                map[trip.tripId] = trip;
                continue;
              }
              // 2. Actively assigned state supersedes unassigned/preliminary snapshot.
              if (isAssignedDriver &&
                  existing.driver?.driverId != userId &&
                  existing.driverId != userId) {
                map[trip.tripId] = trip;
                continue;
              }
              // 3. Later activity timestamp supersedes earlier.
              if (trip.latestActivityDate.isAfter(existing.latestActivityDate)) {
                map[trip.tripId] = trip;
                continue;
              }
            } else {
              map[trip.tripId] = trip;
            }
          } catch (e) {
            debugPrint('Error parsing trip doc ${doc.id}: $e');
          }
        }
        final list = map.values.toList();
        list.sort((a, b) => _compareTripDate(a, b));
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

            // Server-maintained mirror (`onTripWrittenForDriverHistory`):
            // reading `drivers/{uid}/trip_history` is provably safe — the
            // owner-only rule passes the query-validation proof, unlike the
            // disjunctive `trips` read rule (which rejects array-contains
            // list queries outright).
            subAttempted = _db
                .collection('drivers')
                .doc(userId)
                .collection('trip_history')
                .snapshots()
                .listen(
              (snap) {
                attemptedDocs = snap.docs;
                emitCombined();
              },
              onError: (err) {
                debugPrint('userTripHistoryStream (drivers/{uid}/trip_history) error: $err');
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
          subAttempted?.cancel();
        },
      );

      return controller.stream;
    } catch (e) {
      debugPrint('FirestoreTripRepository.userTripHistoryStream error: $e');
      return Stream.value(const []);
    }
  }

  static int _compareTripDate(ActiveTrip a, ActiveTrip b) {
    return b.latestActivityDate.compareTo(a.latestActivityDate);
  }

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('cancelTrip').call({
      'tripId': tripId,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      if (useCashSettlement) 'useCashSettlement': true,
    }));
  }

  @override
  Future<void> confirmCashCancellation(String tripId) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('confirmCashCancellation').call({'tripId': tripId}));
  }

  Future<T> _callWithAuthRetry<T>(Future<T> Function() callable) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const TripException(
        'unauthenticated',
        'Your session has expired. Please sign in again.',
      );
    }
    try {
      return await callable();
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'unauthenticated') {
        debugPrint('FirestoreTripRepository: unauthenticated response, refreshing token and retrying...');
        try {
          await user.getIdToken(true);
          return await callable();
        } catch (retryErr) {
          debugPrint('FirestoreTripRepository: token refresh retry failed: $retryErr');
          if (retryErr is FirebaseFunctionsException) {
            throw TripException(retryErr.code, _mapError(retryErr.code, retryErr.message));
          }
          throw TripException('unauthenticated', _mapError('unauthenticated', e.message));
        }
      }
      throw TripException(e.code, _mapError(e.code, e.message));
    } catch (e) {
      if (e is TripException) rethrow;
      debugPrint('FirestoreTripRepository call error: $e');
      throw const TripException(
        'network-error',
        'Could not reach the dispatch server. Check your connection and try again.',
      );
    }
  }

  // ── Bidding ────────────────────────────────────────────────────────────────

  @override
  Future<void> submitBid(
    String tripId,
    double offeredFare, {
    int? etaMinutes,
  }) async {
    final payload = <String, dynamic>{
      'tripId': tripId,
      'offeredFare': offeredFare,
    };
    if (etaMinutes != null) payload['etaMinutes'] = etaMinutes;
    await _callWithAuthRetry(() => _fn.httpsCallable('submitBid').call(payload));
  }

  @override
  Future<void> rejectBid(String tripId, String driverId) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('rejectBid').call({
      'tripId': tripId,
      'driverId': driverId,
    }));
  }

  @override
  Future<void> acceptBid(String tripId, String driverId) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('acceptBid').call({
      'tripId': tripId,
      'driverId': driverId,
    }));
  }

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('increaseTripFare').call({
      'tripId': tripId,
      'newFare': newFare,
    }));
  }

  @override
  Future<void> reassignTrip(String tripId, {double? newFare}) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('reassignTrip').call({
      'tripId': tripId,
      if (newFare != null && newFare > 0) 'newFare': newFare,
    }));
  }

  @override
  Future<void> keepSearchingTrip(String tripId) async {
    await _callWithAuthRetry(() => _fn.httpsCallable('keepSearchingTrip').call({
      'tripId': tripId,
    }));
  }

  @override
  Stream<List<BidModel>> bidsStream(String tripId) {
    if (tripId.isEmpty) return Stream.value(const <BidModel>[]);
    return _db
        .collection('trips')
        .doc(tripId)
        .collection('bids')
        .snapshots()
        .map((snap) {
          final bids = snap.docs
              .map((d) => BidModel.fromMap(d.id, d.data()))
              .toList();
          bids.sort((a, b) {
            final aTime = a.createdAt?.millisecondsSinceEpoch ?? 0;
            final bTime = b.createdAt?.millisecondsSinceEpoch ?? 0;
            return bTime.compareTo(aTime);
          });
          return bids;
        })
        .handleError((err) {
      debugPrint('bidsStream error: $err');
      return <BidModel>[];
    });
  }

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) {
    if (driverId.isEmpty) return Stream.value(null);
    return _db
        .collectionGroup('bids')
        .where('driverId', isEqualTo: driverId)
        .snapshots()
        .map((snap) {
      for (final doc in snap.docs) {
        final bid = BidModel.fromMap(doc.id, doc.data());
        if (bid.status == BidStatus.pending && !bid.isExpired) {
          return bid;
        }
      }
      return null;
    }).handleError((err) {
      debugPrint('activeDriverBidStream error: $err');
      return null;
    });
  }

  @override
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) {
    if (tripId.isEmpty || driverId.isEmpty) return Stream.value(null);
    return _db
        .collection('trips')
        .doc(tripId)
        .collection('bids')
        .doc(driverId)
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) return null;
      return BidModel.fromMap(doc.id, doc.data()!);
    }).handleError((err) {
      debugPrint('driverBidForTripStream error: $err');
      return null;
    });
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
