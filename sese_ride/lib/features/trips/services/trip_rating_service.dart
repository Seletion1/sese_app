import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service managing post-trip 1-to-5 star ratings and atomic cumulative score updates.
class TripRatingService {
  final FirebaseFirestore _db;

  TripRatingService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  /// Saves a review record in the `ratings` collection (`ratings/{tripId}_{raterId}`)
  /// and atomically updates the rated user's profile score (`averageRating = totalRatingSum / totalRatingCount`).
  Future<void> submitRating({
    required String tripId,
    required String raterId,
    required String ratedUserId,
    required int rating,
    String? comment,
    bool isRatedUserDriver = false,
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
      'timestamp': FieldValue.serverTimestamp(),
    };

    try {
      try {
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (_) {}

      await _db.runTransaction((tx) async {
        final existing = await tx.get(ratingRef);
        if (existing.exists) {
          return;
        }

        // 1. Write the rating document
        tx.set(ratingRef, ratingData);

        // 2. Read target user document to compute cumulative average
        final userSnap = await tx.get(userRef);
        int currentSum = 0;
        int currentCount = 0;

        if (userSnap.exists) {
          final data = userSnap.data() ?? {};
          currentSum = (data['totalRatingSum'] as num?)?.toInt() ?? 0;
          currentCount = (data['totalRatingCount'] as num?)?.toInt() ?? 0;
        }

        final newSum = currentSum + rating;
        final newCount = currentCount + 1;
        final newAverage = newCount > 0 ? (newSum / newCount) : 5.0;

        // 3. Atomically update user document
        tx.set(
          userRef,
          {
            'totalRatingSum': FieldValue.increment(rating),
            'totalRatingCount': FieldValue.increment(1),
            'averageRating': newAverage,
          },
          SetOptions(merge: true),
        );

        // 4. Update driver document if rated party is a driver
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
      debugPrint('TripRatingService.submitRating transaction failed: $e; using direct write fallback');
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

  /// Checks if [raterId] has already rated [tripId].
  Future<bool> hasRated(String tripId, String raterId) async {
    try {
      final doc =
          await _db.collection('ratings').doc('${tripId}_$raterId').get();
      return doc.exists;
    } catch (_) {
      return false;
    }
  }
}
