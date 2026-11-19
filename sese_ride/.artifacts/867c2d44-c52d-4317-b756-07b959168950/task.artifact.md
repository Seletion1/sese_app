# Implementation Task Checklist - 1 Driver Dispatch & 15s Timeout Tunables

- [x] Update `DispatchTuning` model in `sese_core` with `maxSequentialDrivers` (default `1`), `tier1TimeoutSec` (15s), `bidCountdownSec` (15s)
- [x] Update `functions/src/trips.ts` for 1-driver sequential dispatch escalation to Public Pool and 15s default timeouts
- [x] Update Hub Dispatch Console in `global_config_screen.dart` with `maxSequentialDrivers` controls
- [x] Update backend unit tests in `functions/src/test/`
- [x] Run backend unit test suite (`npm test`)
- [x] Run static code analysis (`flutter analyze`) across packages
- [x] Run `flutter test` in `sese_core` and `sese_hub`
- [x] Execute mandatory build, test & Firebase deployment pipeline
- [x] Create `walkthrough.artifact.md`
