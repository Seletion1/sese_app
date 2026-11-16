# Remove Debug-Signing Fallbacks & Secure Release Build Configurations

Fix insecure debug-signing fallbacks and hardcoded debug release configurations across `sese_ride` and `sese_hub` Android build scripts to prevent accidental generation or distribution of debug-signed release artifacts.

## User Review Required

> [!IMPORTANT]
> - **`sese_ride`**: The release build variant will no longer silently fall back to `signingConfigs.getByName("debug")` if `key.properties`, `local.properties`, or environment variables are missing. It will throw an explicit Gradle build error (`GradleException`) detailing the missing release keystore properties.
> - **`sese_hub`**: The hardcoded debug signing configuration (`signingConfigs.getByName("debug")`) in the release build block will be replaced with a secure release signing loader that throws a `GradleException` if release keystore properties are absent.
> - **Version Control Protection**: Keystores (`*.jks`, `*.keystore`) and `key.properties` will be explicitly ignored in `.gitignore` across root, `sese_ride`, and `sese_hub`.
> - **CI / Local Setup Guidance**: A setup guide (`KEYSTORE_SETUP.md`) will document environment variables (`RELEASE_STORE_FILE`, `RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD`) and `key.properties` configuration for CI/CD pipelines (e.g. GitHub Actions).

## Proposed Changes

### Android Build Configuration (`sese_ride`)

#### [MODIFY] [build.gradle.kts](file:///Users/micheal/sese_app/sese_ride/android/app/build.gradle.kts)
- Replace the debug-fallback else block in `signingConfigs.create("release")` with an explicit `throw GradleException(...)` message when release keystore properties are missing.

### Android Build Configuration (`sese_hub`)

#### [MODIFY] [build.gradle.kts](file:///Users/micheal/sese_app/sese_hub/android/app/build.gradle.kts)
- Add `localProps` loader at top of file.
- Add `signingConfigs { create("release") { ... } }` block that loads `key.properties` / `local.properties` / environment variables and throws `GradleException` if missing.
- In `buildTypes { release { ... } }`, set `signingConfig = signingConfigs.getByName("release")` instead of `signingConfigs.getByName("debug")`.

### Version Control & Documentation

#### [MODIFY] [sese_hub/.gitignore](file:///Users/micheal/sese_app/sese_hub/.gitignore) & [sese_app/.gitignore](file:///Users/micheal/sese_app/.gitignore)
- Ensure `key.properties`, `**/key.properties`, `*.jks`, and `*.keystore` are ignored.

#### [NEW] [KEYSTORE_SETUP.md](file:///Users/micheal/sese_app/KEYSTORE_SETUP.md)
- Document how to set up `key.properties` locally and how to inject release keystore environment variables in CI/CD pipelines (e.g., GitHub Actions secrets).

---

## Verification Plan

### Automated Verification
- Run `flutter analyze` in `sese_ride` and `sese_hub`.
- Run `npm run build` in `functions/`.

### Gradle Build Verification
- Execute `gradlew tasks` or dry-run Gradle configuration in `sese_ride/android` and `sese_hub/android` to confirm build scripts parse cleanly.
- Verify that attempting a release build without release keys throws the expected descriptive Gradle build error rather than generating a debug-signed release APK.
