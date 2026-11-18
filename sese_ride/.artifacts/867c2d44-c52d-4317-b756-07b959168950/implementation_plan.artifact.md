# Firebase Crashlytics Integration (`H-2`)

Integrate `firebase_crashlytics` into `sese_core`, `sese_ride`, and `sese_hub` to automatically record unhandled Flutter framework errors, async isolate crashes, and native exceptions to the Firebase console alongside local `crash_reports` logging.

## User Review Required

> [!IMPORTANT]
> - **Dependency Additions**:
>   - Add `firebase_crashlytics: ^4.3.0` to `sese_core/pubspec.yaml`, `sese_ride/pubspec.yaml`, and `sese_hub/pubspec.yaml`.
> - **CrashReporterService Integration**:
>   - Wire `FirebaseCrashlytics.instance.recordFlutterFatalError` and `FirebaseCrashlytics.instance.recordError` into `CrashReporterService.initialize()` (`FlutterError.onError` and `PlatformDispatcher.instance.onError`).
>   - Ensure lazy initialization and try/catch guards so unit tests and headless environments gracefully fall back without throwing `no-app` exceptions.

## Proposed Changes

### Shared Core & App Packages

#### [MODIFY] [sese_core/pubspec.yaml](file:///Users/micheal/sese_app/sese_core/pubspec.yaml)
- Add `firebase_crashlytics: ^4.3.0` under dependencies.

#### [MODIFY] [sese_ride/pubspec.yaml](file:///Users/micheal/sese_app/sese_ride/pubspec.yaml)
- Add `firebase_crashlytics: ^4.3.0` under dependencies.

#### [MODIFY] [sese_hub/pubspec.yaml](file:///Users/micheal/sese_app/sese_hub/pubspec.yaml)
- Add `firebase_crashlytics: ^4.3.0` under dependencies.

#### [MODIFY] [crash_reporter_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/crash_reporter_service.dart)
- Wire `FirebaseCrashlytics` into `FlutterError.onError` and `PlatformDispatcher.instance.onError` within `CrashReporterService.initialize()`.

---

## Verification Plan

### Automated Test Execution
- Run `flutter pub get` in `sese_core`, `sese_ride`, `sese_hub`.
- Run `flutter analyze` across `sese_core`, `sese_hub`, `sese_ride`.
- Run `flutter test` unit tests in `sese_core`.
- Run `npm test` in `functions/`.

### Deployment Pipeline
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: integrate Firebase Crashlytics for automated crash reporting`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
