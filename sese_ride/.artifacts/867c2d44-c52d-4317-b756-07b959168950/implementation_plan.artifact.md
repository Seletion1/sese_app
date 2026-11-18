# Desktop View / Mobile View Toggle Feature (`sese_hub`)

Implement a lightweight, non-destructive View Mode state controller (`ViewModeController`), adaptive viewport scaling wrapper (`AdaptiveViewWrapper`), and settings toggle in `sese_hub` allowing users to seamlessly switch between Auto, Mobile View, and Desktop View ("Request Desktop Site") without restarting the app or losing navigation state.

## User Review Required

> [!IMPORTANT]
> - **1. Global `ViewModeController` State Notifier**:
>   - Create `ViewModeController` (`ValueNotifier<HubViewMode>`) in `sese_hub` / `sese_core`.
>   - Options: `auto` (default: respects device viewport), `mobile` (forces mobile layout bounds), `desktop` (forces 1280px desktop viewport).
>   - Persists user selection in `SharedPreferences` under key `hub_view_mode`.
> - **2. Adaptive Viewport Scaling (`AdaptiveViewWrapper`)**:
>   - Wrap `sese_hub` `MaterialApp.builder` or root Scaffold with `AdaptiveViewWrapper`.
>   - When `ViewMode.desktop` is active on mobile devices, overrides `MediaQuery` with desktop width (1280px) and scales or wraps in horizontal scroll / zoom viewport, mimicking Chrome's "Request Desktop Site".
>   - When `kIsWeb` or running on desktop platforms, defaults cleanly to native full desktop layout.
> - **3. Settings Toggle in `HubSettingsScreen`**:
>   - Add "Desktop View Mode" setting in `HubSettingsScreen` with selection chips / dropdown (`Auto`, `Mobile View`, `Desktop View`).
>   - Changing selection updates state instantly with smooth layout transition without restarting the app or clearing navigation history.

## Proposed Changes

### Shared Core & Hub Packages

#### [NEW] [view_mode_controller.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/dashboard/services/view_mode_controller.dart)
- Create `HubViewMode` enum (`auto`, `mobile`, `desktop`) and `ViewModeController` class backed by `SharedPreferences`.

#### [NEW] [adaptive_view_wrapper.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/dashboard/presentation/adaptive_view_wrapper.dart)
- Create `AdaptiveViewWrapper` widget implementing responsive viewport scaling and desktop mode overrides.

#### [MODIFY] [main.dart](file:///Users/micheal/sese_app/sese_hub/lib/main.dart)
- Wrap `MaterialApp.builder` with `ListenableBuilder(listenable: ViewModeController.instance)` and `AdaptiveViewWrapper`.

#### [MODIFY] [hub_settings_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/settings/hub_settings_screen.dart)
- Add "View Mode / Layout" section with mode selector (`Auto`, `Mobile View`, `Desktop View`) linked to `ViewModeController`.

---

## Verification Plan

### Automated Test & Analysis Execution
- Run `flutter analyze` across `sese_hub`, `sese_core`, `sese_ride`.
- Run `flutter test` unit tests in `sese_hub`.
- Run `npm test` in `functions/`.

### Deployment Pipeline
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: implement desktop/mobile view mode toggle in sese_hub`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
