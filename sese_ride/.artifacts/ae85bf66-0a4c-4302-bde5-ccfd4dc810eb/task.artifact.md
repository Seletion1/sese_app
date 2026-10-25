# Unified Real-Time Trips Feed Tasks

- [x] 1. Extend `TripRepository` (`trip_service.dart`)
  - [x] Add `userTripHistoryStream(String userId, {bool isDriver = false})` to `TripRepository` and `FirestoreTripRepository`
- [x] 2. Unified Trips Feed UI (`customer_trips_screen.dart`)
  - [x] Replace active-only filter with real-time chronological trip activity feed
  - [x] Render rich trip cards with timestamp, fare amount, route summary, and status badges
  - [x] Display clean empty state ("No trips available yet") when no trips exist
- [x] 3. Integrate Driver Shell & Menu (`driver_home_shell.dart`)
  - [x] Delete static "Active trips" and "Ride history" cards from `_TripsTab`
  - [x] Wire `_TripsTab` and side Menu "Trips History" directly to the unified feed
- [x] 4. Testing & Verification
  - [x] Update unit & widget tests in `driver_menu_nav_test.dart`
  - [x] Run `flutter analyze`
  - [x] Run `flutter test`
