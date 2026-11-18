# Dynamic Map & API Key Management & Startup Credential Injection

Implement a dedicated "Map & API Key Management" section in `sese_hub` backed by Firestore `system_config/api_keys`, and update the startup sequence in `sese_ride` to dynamically fetch and inject platform-specific map credentials with graceful build-time fallback.

## User Review Required

> [!IMPORTANT]
> - **1. Firestore Schema & Security Rules (`system_config/api_keys`)**:
>   - Firestore document `system_config/api_keys`:
>     - `active_map_provider`: `'google'` | `'mapbox'`
>     - `google_maps`: `{ android_key, ios_key, web_key }`
>     - `mapbox`: `{ android_token, ios_token, web_token }`
>   - Security rules: `allow read: if isAuthenticated();` and `allow write: if isHubStaff() || isSuperAdmin() || (isAdminAuthClaim() && claimsScopeContains(scopeCodeOf('manageSystemSettings')));`.
> - **2. Hub Admin Dashboard Section (`sese_hub`)**:
>   - Dedicated "Map & API Key Management" card in `global_config_screen.dart` with inputs for Google Maps (Android, iOS, Web) and Mapbox (Android, iOS, Web).
>   - "Save API Key Configuration" button validating non-empty key entries for active providers before persisting to `system_config/api_keys`.
> - **3. App Startup Credential Injection (`sese_ride` & `sese_core`)**:
>   - On app launch, query `system_config/api_keys` via `ApiKeysService.fetchApiKeys()` (4s timeout).
>   - Platform-Specific Injection:
>     - If `active_map_provider == "google"`: inject `google_maps.android_key` on Android or pass `google_maps.ios_key` on iOS.
>     - If `active_map_provider == "mapbox"`: initialize Mapbox options with `mapbox.android_token` or `mapbox.ios_token`.
>   - Fallback: Gracefully fall back to build-time environment variables (`GOOGLE_MAPS_API_KEY`) if offline or timed out.

## Proposed Changes

### Shared Core Package (`sese_core`)

#### [NEW] [api_keys_config.dart](file:///Users/micheal/sese_app/sese_core/lib/models/api_keys_config.dart)
- Create `ApiKeysConfig` model with `fromMap` / `toMap` for `active_map_provider`, `google_maps` keys, and `mapbox` tokens.

#### [NEW] [api_keys_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/api_keys_service.dart)
- Create `ApiKeysService` for fetching, streaming, and saving `system_config/api_keys`.

#### [MODIFY] [sese_core.dart](file:///Users/micheal/sese_app/sese_core/lib/sese_core.dart)
- Barrel export `api_keys_config.dart` and `api_keys_service.dart`.

### Firestore Security Rules

#### [MODIFY] [firestore.rules](file:///Users/micheal/sese_app/firestore.rules)
- Add security rule for `match /system_config/api_keys` allowing authenticated reads and admin/staff writes.

### Hub Portal (`sese_hub`)

#### [MODIFY] [global_config_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/config/presentation/global_config_screen.dart)
- Add "Map & API Key Management" section with inputs for Google Maps and Mapbox keys/tokens and validation on save.

### Customer & Driver App (`sese_ride`)

#### [MODIFY] [main.dart](file:///Users/micheal/sese_app/sese_ride/lib/main.dart)
- Update startup sequence to query `ApiKeysService.fetchApiKeys()` and dynamically configure map credentials and `MapConfigController`.

---

## Verification Plan

### Automated Test Execution
- Run `flutter analyze` in `sese_core`, `sese_hub`, and `sese_ride`.
- Run `flutter test` unit tests in `sese_core`.
- Run `npm test` in `functions/`.

### Deployment Pipeline
- Deploy Firestore security rules and backend functions via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: implement dynamic map & API key management and startup credential injection`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
