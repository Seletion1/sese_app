import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  final FirebaseFirestore _db;

  TripRatingService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

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
    final ratingRef = _db.collection('ratings').doc(ratingDocId);
    final userRef = _db.collection('users').doc(ratedUserId);
    final driverRef =
        isRatedUserDriver ? _db.collection('drivers').doc(ratedUserId) : null;

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
      // Ensure fresh auth token so the Firestore security rule read succeeds.
      try {
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (_) {}

      await _db.runTransaction((tx) async {
        final existing = await tx.get(ratingRef);
        if (existing.exists) return; // idempotent — no double-counting

        // 1. Write the rating document.
        tx.set(ratingRef, ratingData);

        // 2. Read current cumulative totals from users/{ratedUserId}.
        final userSnap = await tx.get(userRef);
        final userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
        final currentSum = (userData['totalRatingSum'] as num?)?.toInt() ?? 0;
        final currentCount =
            (userData['totalRatingCount'] as num?)?.toInt() ?? 0;

        final newSum = currentSum + rating;
        final newCount = currentCount + 1;
        final newAverage = newSum / newCount;

        // 3. Atomically update users/{ratedUserId}.
        tx.set(
          userRef,
          {
            'totalRatingSum': FieldValue.increment(rating),
            'totalRatingCount': FieldValue.increment(1),
            'averageRating': newAverage,
          },
          SetOptions(merge: true),
        );

        // 4. Mirror to drivers/{ratedUserId} when the rated party is a driver.
        if (driverRef != null) {
          tx.set(
            driverRef,
            {
              'totalRatingSum': FieldValue.increment(rating),
              'totalRatingCount': FieldValue.increment(1),
              'averageRating': newAverage,
              'rating': newAverage,
            },
            SetOptions(merge: true),
          );
        }
      });
    } catch (e) {
      debugPrint(
          'TripRatingService.submitRating transaction failed: $e; falling back to direct write');
      try {
        await ratingRef.set(ratingData, SetOptions(merge: true));
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
      } catch (inner) {
        debugPrint('TripRatingService.submitRating fallback error: $inner');
        rethrow;
      }
    }
  }

  /// Returns true if [raterId] has already submitted a rating for [tripId].
  Future<bool> hasRated(String tripId, String raterId) async {
    try {
      final doc =
          await _db.collection('ratings').doc('${tripId}_$raterId').get();
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
    try {
      await _db
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
