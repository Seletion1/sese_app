# Walkthrough - Dynamic Map & API Key Management & Startup Credential Injection

## Summary of Implementation

Implemented a dedicated "Map & API Key Management" section in `sese_hub` backed by Firestore `system_config/api_keys`, and updated `sese_ride` app startup to dynamically fetch and inject platform-specific map credentials with graceful build-time fallback.

### 1. Shared Models & Service (`sese_core`)
**[api_keys_config.dart](file:///Users/micheal/sese_app/sese_core/lib/models/api_keys_config.dart)** & **[api_keys_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/api_keys_service.dart)**
- Created `ApiKeysConfig` model supporting platform-specific credentials:
  - `active_map_provider`: `'google'` | `'mapbox'`
  - `google_maps`: `{ android_key, ios_key, web_key }`
  - `mapbox`: `{ android_token, ios_token, web_token }`
- Created `ApiKeysService` to stream, fetch (4s timeout), and save `system_config/api_keys`.

### 2. Firestore Security Rules
**[firestore.rules](file:///Users/micheal/sese_app/firestore.rules#L1500-L1515)**
- Added security rules for `match /system_config/api_keys`:
  - `allow read: if isAuthenticated();` (authenticated riders and drivers read map keys).
  - `allow write: if isHubStaff() || isSuperAdmin() || (isAdminAuthClaim() && claimsScopeContains(scopeCodeOf('manageSystemSettings')));`.

### 3. Hub Admin Dashboard ("Map & API Key Management")
**[global_config_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/config/presentation/global_config_screen.dart#L2920-L2985)**
- Implemented `_buildApiKeysCard()` in `global_config_screen.dart` with:
  - Active Map Provider dropdown (`Google Maps` vs `Mapbox`).
  - Google Maps Form Inputs: Android API Key, iOS API Key, Web API Key.
  - Mapbox Form Inputs: Android Access Token, iOS Access Token, Web Access Token.
  - "Publish Config" button validation ensuring empty keys cannot be saved accidentally when active provider requires them.

### 4. App Startup Credential Injection (`sese_ride`)
**[main.dart](file:///Users/micheal/sese_app/sese_ride/lib/main.dart#L230-L280)**
- Added `_initDynamicMapCredentials()` in `sese_ride/lib/main.dart` called on startup:
  - Fetches `system_config/api_keys` with a 4s deadline.
  - On Android: injects `google_maps.android_key` or `mapbox.android_token`.
  - On iOS: passes `google_maps.ios_key` or `mapbox.ios_token` to `GMSServices.provideAPIKey()`.
  - Updates `MapConfigController.instance` dynamically.
  - If offline or timed out, falls back gracefully to build-time environment variables (`GlobalMapConfig.defaultGoogleMapsApiKey`).

---

## Verification Results

### Automated Tests & Pipeline Execution
- **Flutter Code Analysis (`flutter analyze`)**: Passed cleanly across `sese_core`, `sese_hub`, and `sese_ride` with 0 issues.
- **Backend Unit Tests (`npm test`)**: All 146 backend unit tests passed across 48 test suites with 0 failures.
- **Firebase Deployment**: All 78 Cloud Functions, Firestore rules, and Storage rules updated successfully live on `sese-ride`.
- **Git Sync**: Staged, committed, and pushed commit `fce8152` to `https://github.com/Seletion1/sese_app.git` on branch `main`.
