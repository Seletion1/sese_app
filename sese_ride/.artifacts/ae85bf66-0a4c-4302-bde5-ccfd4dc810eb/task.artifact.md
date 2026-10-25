# Driver Earnings Pill & 4-Tab Bottom Navigation Tasks

- [/] 1. Refactor Top Floating Earnings Pill Box
  - [ ] Remove icon and "Daily Earnings: " text from `_buildDailyEarningsCounter()` in `driver_dashboard_screen.dart`
  - [ ] Render strictly raw total amount (e.g. `₦4,126.00`)
  - [ ] Wrap pill box in interactive `InkWell` to open `EarningsScreen` on tap
- [/] 2. Update Bottom Navigation to 4 Tabs
  - [ ] Remove "Earnings" tab item from `BottomNavigationBar` in `driver_home_shell.dart`
  - [ ] Update tab items (Menu [0], Home [1], Trips [2], Help [3])
  - [ ] Update default index `_currentIndex = 1` and `_homeIndex = 1`
  - [ ] Remove `EarningsScreen` from `IndexedStack`
  - [ ] Update `_MenuTab` navigation callbacks and `_handlePopInvoked`
- [/] 3. Update Tests & Verification
  - [ ] Update `test/driver_menu_nav_test.dart`
  - [ ] Run `flutter analyze`
  - [ ] Run `flutter test`
