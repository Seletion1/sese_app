# Complete & Clean Removal of Zego Engine

Perform a complete removal of Zego from the codebase (`sese_core`, `sese_hub`, `sese_ride`, and `functions`). Calling architecture will route exclusively through WebRTC (Firebase signaling) and Agora RTC.

## User Review Required

> [!IMPORTANT]
> - **1. Deletion of Zego Call Implementation (`sese_core`)**:
>   - Delete `sese_core/lib/services/call/zego_call_service_impl.dart`.
>   - Remove `zego` value from `CallProviderType` enum (`i_call_service.dart`). Active calling providers will be `webrtc` and `agora`.
>   - Remove `ZegoCallServiceImpl` and `_zegoService` references from `CallServiceManager` (`call_service_manager.dart`).
>   - Remove `zegoAppId`, `zegoAppSign`, `hasValidZegoCredentials`, `_kPrefZegoAppId`, `_kPrefZegoAppSign` from `CallConfigRepository` (`call_config_repository.dart`).
>   - Remove `export 'services/call/zego_call_service_impl.dart';` from `sese_core.dart`.
> - **2. Hub Admin UI & Calling Config (`sese_hub`)**:
>   - Update `CallingConfigScreen` (`calling_config_screen.dart`) and `HubSettingsScreen` (`hub_settings_screen.dart`) to remove Zego provider controls, Zego App ID/Sign fields, and Zego test actions.
> - **3. Backend Functions Purge (`functions/`)**:
>   - Remove `getZegoToken` Cloud Function from `functions/src/callTokens.ts` and `functions/src/index.ts`.

## Proposed Changes

### Shared Core Package (`sese_core`)

#### [DELETE] [zego_call_service_impl.dart](file:///Users/micheal/sese_app/sese_core/lib/services/call/zego_call_service_impl.dart)
- Delete `zego_call_service_impl.dart`.

#### [MODIFY] [i_call_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/call/i_call_service.dart)
- Remove `zego` entry from `CallProviderType` enum.

#### [MODIFY] [call_config_repository.dart](file:///Users/micheal/sese_app/sese_core/lib/services/call/call_config_repository.dart)
- Remove `zegoAppId`, `zegoAppSign`, `hasValidZegoCredentials`, and `_kPrefZegoAppId` / `_kPrefZegoAppSign` preferences.

#### [MODIFY] [call_service_manager.dart](file:///Users/micheal/sese_app/sese_core/lib/services/call/call_service_manager.dart)
- Remove `_zegoService` instance and `CallProviderType.zego` routing logic.

#### [MODIFY] [sese_core.dart](file:///Users/micheal/sese_app/sese_core/lib/sese_core.dart)
- Remove `export 'services/call/zego_call_service_impl.dart';`.

#### [MODIFY] [call_service_test.dart](file:///Users/micheal/sese_app/sese_core/test/call_service_test.dart)
- Clean up Zego unit test assertions.

### Hub Portal (`sese_hub`)

#### [MODIFY] [calling_config_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/settings/calling_config_screen.dart)
- Remove Zego provider selection, Zego credentials inputs, and Zego test buttons.

#### [MODIFY] [hub_settings_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/settings/hub_settings_screen.dart)
- Update calling configuration tile subtitle.

### Cloud Functions Backend (`functions/src`)

#### [MODIFY] [callTokens.ts](file:///Users/micheal/sese_app/functions/src/callTokens.ts)
- Remove `getZegoToken` function.

#### [MODIFY] [index.ts](file:///Users/micheal/sese_app/functions/src/index.ts)
- Remove `getZegoToken` export.

---

## Verification Plan

### Automated Test & Analysis Execution
- Run `flutter analyze` across `sese_core`, `sese_hub`, and `sese_ride`.
- Run `flutter test` unit tests in `sese_core`.
- Run `npm run build` and `npm test` in `functions/`.

### Deployment Pipeline
- Deploy backend functions and security rules via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `refactor: perform complete and clean removal of Zego engine from codebase`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
