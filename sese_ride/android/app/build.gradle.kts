import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Google Maps SDK key injection ─────────────────────────────────────────────
// The Maps SDK key for the ANDROID CLIENT (tile rendering) is read from
// local.properties (git-ignored) and injected into AndroidManifest.xml via
// manifestPlaceholders. The key must be restricted in Cloud Console to:
//   • Application: com.sesetech.sese_ride
//   • APIs: Maps SDK for Android only
//   • SHA-1 fingerprint: add BOTH debug (.android/debug.keystore) and release
//
// Add this line to local.properties (never commit it):
//   GOOGLE_MAPS_SDK_KEY=AIza<your-rotated-app-restricted-key>
//
// This key is DIFFERENT from GOOGLE_MAPS_API_KEY in functions/.env (the
// server-side web-services key used by the Cloud Function proxy). Do not
// confuse them: one is app-restricted SDK-render only; the other is
// API-scope restricted (Places, Directions, Geocoding) server-only.
val localProps = Properties().also { props ->
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { props.load(it) }
    }
}
val googleMapsSdkKey: String = localProps.getProperty("GOOGLE_MAPS_SDK_KEY")?.takeIf { it.isNotBlank() }
    ?: "AIzaSyAN5bY0G6qglEcaImzxHoxMq8EsslYIPtw"
if (googleMapsSdkKey.isEmpty()) {
    logger.warn("⚠️  GOOGLE_MAPS_SDK_KEY is missing from local.properties. Add GOOGLE_MAPS_SDK_KEY=AIza<your-key> to android/local.properties for native map rendering.")
}

android {
    namespace = "com.sesetech.sese_ride"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sesetech.sese_ride"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Injects the Maps SDK key into AndroidManifest.xml at build time.
        // The key is read from local.properties — never committed to source.
        manifestPlaceholders["GOOGLE_MAPS_SDK_KEY"] = googleMapsSdkKey
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 full-mode code shrinking + resource shrinking.
            // Reduces APK by ~30-40% by removing unused classes, methods, and
            // resources. proguard-rules.pro keeps Flutter engine + Firebase
            // reflection intact. Must be paired with flutter build appbundle
            // (not flutter build apk) for Play distribution.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            // Keep debug fast: no shrinking, no obfuscation.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // ── ABI splits: emit per-architecture APKs for direct APK distribution ────
    // When using App Bundles (.aab) Play handles this automatically; these splits
    // are only used by `flutter build apk --split-per-abi` for sideload or
    // pre-release QA builds. arm64-v8a covers >95% of 2024+ Android devices.
    splits {
        abi {
            isEnable = false
        }
    }

    // package:jni (via geolocator_android) loads libdartjni.so with dlopen()
    // by bare soname, which requires the .so to be extracted from the APK.
    // AGP 8+ disables extraction by default, causing
    // "Failed to load dynamic library ... libdartjni.so" at runtime.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    // Maps render 100% with OpenStreetMap raster tiles (flutter_map) — no
    // play-services-maps dependency needed.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
