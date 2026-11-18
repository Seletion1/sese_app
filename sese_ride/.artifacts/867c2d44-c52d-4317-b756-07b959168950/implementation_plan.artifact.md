# Strict Release Build Signing Verification (`H-3`)

Enforce strict release signing verification in Android Gradle configuration (`sese_ride` and `sese_hub`). Release builds (`flutter build appbundle`, `assembleRelease`) fail loudly if `key.properties` or release environment signing keys are missing, preventing accidental silent fallback to debug signing for production Play Store uploads.

## User Review Required

> [!IMPORTANT]
> - **Task-Aware Release Signing Protection**:
>   - In `sese_ride/android/app/build.gradle.kts` and `sese_hub/android/app/build.gradle.kts`:
>   - Inspect `gradle.startParameter.taskNames` during signing configuration.
>   - When a **release task** is requested (`assembleRelease`, `bundleRelease`, `flutter build appbundle`, `flutter build apk --release`), require valid release signing properties (`key.properties` or environment variables) and throw a `GradleException` loudly if missing.
>   - For **local debug tasks** (`flutter run`, `assembleDebug`), allow local debug signing fallback so developers can run debug builds seamlessly.

## Proposed Changes

### Android Build Configurations (`android/app/build.gradle.kts`)

#### [MODIFY] [sese_ride build.gradle.kts](file:///Users/micheal/sese_app/sese_ride/android/app/build.gradle.kts#L85-L105)
- Add task-aware `isReleaseRequested` check to `signingConfigs.create("release")` throwing `GradleException` loudly on release tasks when release keys are missing.

#### [MODIFY] [sese_hub build.gradle.kts](file:///Users/micheal/sese_app/sese_hub/android/app/build.gradle.kts#L50-L75)
- Add task-aware `isReleaseRequested` check to `signingConfigs.create("release")` throwing `GradleException` loudly on release tasks when release keys are missing.

---

## Verification Plan

### Automated Build & Test Execution
- Run `flutter analyze` across `sese_ride`, `sese_hub`, `sese_core`.
- Run `./gradlew assembleDebug` in `sese_ride/android` to verify debug builds succeed locally.
- Run `npm test` in `functions/`.

### Deployment Pipeline
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `fix: enforce strict release build signing constraints in Gradle`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
