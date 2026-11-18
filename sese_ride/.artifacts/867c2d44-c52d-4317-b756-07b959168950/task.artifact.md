# Implementation Task Checklist - Complete Removal of Zego Engine

- [/] Delete `sese_core/lib/services/call/zego_call_service_impl.dart`
- [/] Remove Zego from `i_call_service.dart`, `call_config_repository.dart`, and `call_service_manager.dart`
- [/] Remove `zego_call_service_impl.dart` export from `sese_core.dart`
- [/] Clean up Zego references in `sese_core/test/call_service_test.dart`
- [/] Update `calling_config_screen.dart` and `hub_settings_screen.dart` in `sese_hub`
- [/] Remove `getZegoToken` from `functions/src/callTokens.ts` and `functions/src/index.ts`
- [ ] Run static code analysis (`flutter analyze`) across packages
- [ ] Run `flutter test` in `sese_core`
- [ ] Run backend unit test suite (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
