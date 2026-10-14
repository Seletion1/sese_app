# SeSe Ride (Customer & Driver Flutter App)

SeSe Ride customer and driver application package.

## Shorebird Over-The-Air (OTA) Code Push

SeSe Ride is integrated with Shorebird to push instant, Over-The-Air Dart fixes to release builds without requiring users to download a new APK/AAB from the app store.

### 1. Prerequisites & Login
First, ensure you are logged into Shorebird CLI on your development/CI machine:
```bash
shorebird login
```

### 2. Initialize App ID (First-time setup per environment)
To link your project to your Shorebird console app:
```bash
shorebird init
```
This updates `shorebird.yaml` with your app's unique `app_id`.

### 3. Release Build (Base App Store / Play Store Build)
Always create your release builds using Shorebird CLI so that Shorebird can capture the release binary symbols:
```bash
# Android Release (AAB for Google Play Store)
shorebird release android

# Android Release (APK for direct distribution)
shorebird release android --artifact=apk
```

### 4. Deploying an OTA Patch (Instant Fix)
When you fix a Dart bug or update UI/business logic in `lib/`, publish an instant patch to all installed release builds:
```bash
shorebird patch android
```
The patch is downloaded silently by `ShorebirdUpdateService` on startup and applied automatically on the user's next cold app restart.
