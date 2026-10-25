# Post-Trip Rating & Cumulative Scoring System Implementation Plan

Implement a secure post-trip rating dialog and cumulative scoring system for drivers and customers across `sese_core` and `sese_ride`.

## Proposed Changes

### 1. Core User Model & Rating Service (`sese_core` & `sese_ride`)

#### [MODIFY] [user_model.dart](file:///Users/micheal/sese_app/sese_core/lib/models/user_model.dart)
- Add rating aggregation fields to `AppUser`:
  - `double averageRating` (default 5.0 or 0.0)
  - `int totalRatingSum` (default 0)
  - `int totalRatingCount` (default 0)
- Update `toMap`, `fromMap`, and `copyWith` accordingly.

#### [NEW] [trip_rating_service.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/services/trip_rating_service.dart)
- Create `TripRatingService` to handle Firestore rating records and atomic profile score recalculations:
  - `submitRating`: Writes to `ratings/{tripId}_{raterId}` collection with `tripId`, `raterId`, `ratedUserId`, `rating`, `comment`, and `timestamp`.
  - Runs a Firestore transaction to update `users/{ratedUserId}` (and `drivers/{ratedUserId}` if driver):
    - `totalRatingSum += rating`
    - `totalRatingCount += 1`
    - `averageRating = totalRatingSum / totalRatingCount`
  - Maintains `hasRated(tripId, raterId)` check to prevent duplicate rating prompts.

---

### 2. Rating Modal UI Widget (`sese_ride`)

#### [NEW] [trip_rating_dialog.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/trip_rating_dialog.dart)
- Create `TripRatingDialog`:
  - Interactive 1-to-5 star selector with gold fill animations.
  - Optional feedback text field for comments.
  - "Submit Rating" button and a clean "Skip" option.
  - Tapping Skip or Submit cleanly dismisses the modal and commits the state.

---

### 3. Integration & Trip Completion Listener

#### [MODIFY] [driver_dashboard_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/driver_dashboard_screen.dart)
#### [MODIFY] [live_trip_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/live_trip_screen.dart)
- Wire the rating trigger into the completion state listener:
  - When trip status transitions to `TripStatus.completed`, check if the user has already rated/skipped.
  - Automatically show `TripRatingDialog` if unrated.
  - Ensure dismissal allows seamless navigation without blocking the dashboard.

## Verification Plan

### Automated Tests
- Create unit & widget tests in `test/trip_rating_test.dart` verifying:
  - 1–5 star selection and comment submission.
  - Cumulative rating calculation math (`averageRating = totalRatingSum / totalRatingCount`).
  - Modal auto-trigger on trip completion and clean dismissal on Skip/Submit.
- Run `flutter analyze` to ensure 0 errors and 0 warnings.

### Manual Verification
- Verify rating modal appears automatically upon trip completion.
- Verify submitting a 5-star or 4-star rating updates the user's cumulative score in Firestore instantly.
