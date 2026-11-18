# Implementation Task Checklist - Firebase Crashlytics Integration (H-2)

- [/] Add `firebase_crashlytics: ^4.3.0` to `sese_core`, `sese_ride`, and `sese_hub` `pubspec.yaml`
- [/] Wire `FirebaseCrashlytics` into `CrashReporterService.initialize()` in `sese_core`
- [ ] Run `flutter pub get` across `sese_core`, `sese_hub`, `sese_ride`
- [ ] Run static code analysis (`flutter analyze`)
- [ ] Run backend unit test suite (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
