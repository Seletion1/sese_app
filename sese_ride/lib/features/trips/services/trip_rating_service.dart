import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Service managing post-trip 1-to-5 star ratings and atomic cumulative
/// score updates.
///
/// Each rating is stored in `ratings/{tripId}_{raterId}` (one document per
/// direction per trip — driver rates customer, customer rates driver).
/// The rated user's `users/{uid}` document is updated atomically with:
///   - `totalRatingSum`  (running sum for accurate average computation)
///   - `totalRatingCount` (number of ratings received)
///   - `averageRating`  (pre-computed float for fast UI reads)
///
/// For drivers the same fields are mirrored to `drivers/{uid}` so the
/// live-trip driver sheet can read the rating without a cross-collection join.
class TripRatingService {
  final FirebaseFirestore? firestore;
  FirebaseFirestore? _resolvedDb;

  TripRatingService({this.firestore});

  FirebaseFirestore? get _db {
    if (firestore != null) return firestore;
    if (_resolvedDb != null) return _resolvedDb;
    try {
      _resolvedDb = FirebaseFirestore.instance;
      return _resolvedDb;
    } catch (_) {
      return null;
    }
  }

  /// Saves a review record and atomically updates the rated user's profile.
  ///
  /// [lowRatingReasons] — list of chip labels selected when the star rating
  /// is ≤ 3. Stored verbatim for Ops triage. May be empty.
  Future<void> submitRating({
    required String tripId,
    required String raterId,
    required String ratedUserId,
    required int rating,
    String? comment,
    bool isRatedUserDriver = false,
    List<String> lowRatingReasons = const [],
  }) async {
    if (rating < 1 || rating > 5) {
      throw ArgumentError('Rating must be an integer between 1 and 5.');
    }

    final ratingDocId = '${tripId}_$raterId';

    // 1. Primary path: Server-authoritative atomic rating submission via Cloud Functions.
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('submitTripRating');
      await callable.call<Map<String, dynamic>>({
        'tripId': tripId,
        'raterId': raterId,
        'ratedUserId': ratedUserId,
        'rating': rating,
        'comment': (comment ?? '').trim(),
        'isRatedUserDriver': isRatedUserDriver,
        'lowRatingReasons': lowRatingReasons,
      });
      return;
    } catch (fnErr) {
      debugPrint(
          'TripRatingService.submitRating callable failed: $fnErr; falling back to direct write');
    }

    // 2. Fallback path: Direct Firestore write to ratings/{ratingDocId}.
    final db = _db;
    if (db == null) return;
    final ratingRef = db.collection('ratings').doc(ratingDocId);
    final userRef = db.collection('users').doc(ratedUserId);
    final driverRef =
        isRatedUserDriver ? db.collection('drivers').doc(ratedUserId) : null;

    final ratingData = <String, dynamic>{
      'ratingId': ratingDocId,
      'tripId': tripId,
      'raterId': raterId,
      'ratedUserId': ratedUserId,
      'rating': rating,
      'comment': (comment ?? '').trim(),
      if (lowRatingReasons.isNotEmpty) 'lowRatingReasons': lowRatingReasons,
      'isLowRating': rating <= 3,
      'timestamp': FieldValue.serverTimestamp(),
    };

    try {
      await ratingRef.set(ratingData, SetOptions(merge: true));
      try {
        await userRef.set({
          'totalRatingSum': FieldValue.increment(rating),
          'totalRatingCount': FieldValue.increment(1),
        }, SetOptions(merge: true));
        if (driverRef != null) {
          await driverRef.set({
            'totalRatingSum': FieldValue.increment(rating),
            'totalRatingCount': FieldValue.increment(1),
          }, SetOptions(merge: true));
        }
      } catch (_) {}
    } catch (inner) {
      debugPrint('TripRatingService.submitRating fallback error: $inner');
      rethrow;
    }
  }

  /// Returns true if [raterId] has already submitted a rating for [tripId].
  Future<bool> hasRated(String tripId, String raterId) async {
    final db = _db;
    if (db == null) return false;
    try {
      final doc =
          await db.collection('ratings').doc('${tripId}_$raterId').get();
      return doc.exists;
    } catch (_) {
      return false;
    }
  }

  /// Saves cancellation feedback to `cancellation_feedback/{tripId}_{userId}`.
  ///
  /// This is a lightweight write: the cancellation callable already records
  /// the chosen reason on the trip doc; this stores the *additional* free-text
  /// detail and any extra reason chip the user selects in the post-cancel sheet.
  Future<void> submitCancellationFeedback({
    required String tripId,
    required String userId,
    required String role, // 'customer' | 'driver'
    required String reason,
    String detail = '',
  }) async {
    if (tripId.isEmpty || userId.isEmpty || reason.isEmpty) return;
    final db = _db;
    if (db == null) return;
    try {
      await db
          .collection('cancellation_feedback')
          .doc('${tripId}_$userId')
          .set({
        'tripId': tripId,
        'userId': userId,
        'role': role,
        'reason': reason.trim(),
        'detail': detail.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Non-fatal: log and swallow — never surface to the user.
      debugPrint('TripRatingService.submitCancellationFeedback error: $e');
    }
  }
}
