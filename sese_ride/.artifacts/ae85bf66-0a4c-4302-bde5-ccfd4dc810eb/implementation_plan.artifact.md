# Unified Real-Time Trips Feed Implementation Plan

Refactor the Trips tab on both driver and customer apps by permanently deleting static category cards ("Active trips" / "Ride history") and implementing a unified, real-time chronological trip activity feed.

## Proposed Changes

### 1. Trip Service & Repository (`sese_ride`)

#### [MODIFY] [trip_service.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/services/trip_service.dart)
- Add `userTripHistoryStream(String userId, {bool isDriver = false})` to `TripRepository` and `FirestoreTripRepository`.
- Streams all trips (active, completed, cancelled) for the given user/driver ordered newest-first from Firestore `trips` collection.

---

### 2. Unified Trips Feed UI (`sese_ride`)

#### [MODIFY] [customer_trips_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/customer_trips_screen.dart)
- Completely replace static lists / active-only filters with the unified real-time trip activity feed.
- Support both customer and driver modes (`isDriver` flag).
- Renders rich trip cards containing:
  - Date/time timestamp and fare amount (e.g., `₦4,126`).
  - Pickup and Drop-off route summary.
  - Lifecycle status badge: `In Progress`, `Searching...`, `Completed`, `Cancelled by Customer`, `Cancelled by Driver`.
- Shows clean empty state ("No trips available yet") when no trips exist.
- Tapping an active/live trip navigates directly to `LiveTripScreen`.

---

### 3. Driver & Menu Shell Integration (`sese_ride`)

#### [MODIFY] [driver_home_shell.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/home/driver_home_shell.dart)
- Permanently delete static "Active trips" and "Ride history" cards from `_TripsTab`.
- Wire `_TripsTab` directly to `CustomerTripsScreen(customerId: user.uid, isDriver: true)`.
- Ensure side Menu "Trips History" tile opens this same unified real-time feed view.

## Verification Plan

### Automated Tests
- Update unit & widget tests in `test/driver_menu_nav_test.dart` and `test/live_trip_screen_test.dart`.
- Run `flutter analyze` to verify zero static analysis errors and warnings.
- Run `flutter test` across all test suites.

### Manual Verification
- Verify static "Active trips" / "Ride history" cards are permanently removed.
- Verify Trips tab loads a single chronological list of all trips (active, completed, cancelled).
- Verify status badges accurately represent each trip stage.
- Verify side Menu "Trips History" tile loads the exact same unified trip feed.
