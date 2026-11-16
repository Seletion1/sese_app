# Android Release Keystore & Signing Configuration Guide

To ensure security and prevent unauthorized or debug-signed production artifacts, release builds for `sese_ride` and `sese_hub` strictly require valid release signing credentials. If release keystore properties are missing during a release build, Gradle will fail immediately with an explicit error.

---

## 1. Keystore Security Rules

- **NEVER** check release keystores (`*.jks`, `*.keystore`) or `key.properties` files into Git or version control.
- Ensure `key.properties`, `*.jks`, and `*.keystore` are present in your `.gitignore` files.
- Keep backup copies of production keystores in secure, encrypted password managers or secret stores.

---

## 2. Local Development Setup

For local release testing (e.g. `flutter build appbundle --release` or `flutter build apk --release`):

### Option A: `key.properties` File

Create a file named `key.properties` inside the `android/` directory of the app (`sese_ride/android/key.properties` or `sese_hub/android/key.properties`):

```properties
storeFile=/path/to/upload-keystore.jks
storePassword=YourStorePassword
keyAlias=upload
keyPassword=YourKeyPassword
```

### Option B: `local.properties` or Environment Variables

Alternatively, you can supply properties in `android/local.properties` or set system environment variables:

```bash
export RELEASE_STORE_FILE="/path/to/upload-keystore.jks"
export RELEASE_STORE_PASSWORD="YourStorePassword"
export RELEASE_KEY_ALIAS="upload"
export RELEASE_KEY_PASSWORD="YourKeyPassword"
```

---

## 3. CI/CD Secret Injection (GitHub Actions)

In automated CI/CD build pipelines:

1. Base64-encode your upload keystore file:
   ```bash
   base64 -i upload-keystore.jks -o keystore.base64
   ```
2. Store the encoded string and passwords in GitHub Repository Secrets:
   - `RELEASE_KEYSTORE_BASE64`
   - `RELEASE_STORE_PASSWORD`
   - `RELEASE_KEY_ALIAS`
   - `RELEASE_KEY_PASSWORD`

3. In your workflow file (`.github/workflows/build.yml`), decode the keystore and pass environment variables to Gradle/Flutter:

   ```yaml
   - name: Decode Keystore
     run: |
       echo "${{ secrets.RELEASE_KEYSTORE_BASE64 }}" | base64 --decode > android/app/upload-keystore.jks

   - name: Build Android App Bundle
     env:
       RELEASE_STORE_FILE: "app/upload-keystore.jks"
       RELEASE_STORE_PASSWORD: ${{ secrets.RELEASE_STORE_PASSWORD }}
       RELEASE_KEY_ALIAS: ${{ secrets.RELEASE_KEY_ALIAS }}
       RELEASE_KEY_PASSWORD: ${{ secrets.RELEASE_KEY_PASSWORD }}
     run: flutter build appbundle --release
   ```
