# Implementation Task Checklist - 1 Driver Dispatch & 15s Timeout Tunables

- [/] Update `DispatchTuning` model in `sese_core` with `maxSequentialDrivers` (default `1`), `tier1TimeoutSec` (15s), `bidCountdownSec` (15s)
- [/] Update `functions/src/trips.ts` for 1-driver sequential dispatch escalation to Public Pool and 15s default timeouts
- [/] Update Hub Dispatch Console in `global_config_screen.dart` with `maxSequentialDrivers` controls
- [/] Update backend unit tests in `functions/src/test/`
- [ ] Run backend unit test suite (`npm test`)
- [ ] Run static code analysis (`flutter analyze`) across packages
- [ ] Run `flutter test` in `sese_core` and `sese_hub`
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
