import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProps = Properties().also { props ->
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { props.load(it) }
    }
}

android {
    namespace = "com.sesetech.sese_hub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.sesetech.sese_hub"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keyPropertiesFile = rootProject.file("key.properties")
            val releaseProps = Properties()
            if (keyPropertiesFile.exists()) {
                keyPropertiesFile.inputStream().use { releaseProps.load(it) }
            }
            val storeFilePath = releaseProps.getProperty("storeFile")
                ?: localProps.getProperty("RELEASE_STORE_FILE")
                ?: System.getenv("RELEASE_STORE_FILE")
            val storePass = releaseProps.getProperty("storePassword")
                ?: localProps.getProperty("RELEASE_STORE_PASSWORD")
                ?: System.getenv("RELEASE_STORE_PASSWORD")
            val aliasName = releaseProps.getProperty("keyAlias")
                ?: localProps.getProperty("RELEASE_KEY_ALIAS")
                ?: System.getenv("RELEASE_KEY_ALIAS")
            val keyPass = releaseProps.getProperty("keyPassword")
                ?: localProps.getProperty("RELEASE_KEY_PASSWORD")
                ?: System.getenv("RELEASE_KEY_PASSWORD")

            if (!storeFilePath.isNullOrBlank() && !storePass.isNullOrBlank() &&
                !aliasName.isNullOrBlank() && !keyPass.isNullOrBlank()) {
                storeFile = file(storeFilePath)
                storePassword = storePass
                keyAlias = aliasName
                keyPassword = keyPass
            } else {
                throw GradleException(
                    "MISSING RELEASE SIGNING CONFIGURATION:\n" +
                    "Release build requested for sese_hub, but release signing properties were not found.\n" +
                    "Provide a valid key.properties file in android/ or configure local.properties / environment variables:\n" +
                    "  - storeFile (or RELEASE_STORE_FILE)\n" +
                    "  - storePassword (or RELEASE_STORE_PASSWORD)\n" +
                    "  - keyAlias (or RELEASE_KEY_ALIAS)\n" +
                    "  - keyPassword (or RELEASE_KEY_PASSWORD)\n" +
                    "Production release builds must never fall back to debug signing keys."
                )
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")

            // R8 full-mode code shrinking + resource shrinking.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // ABI splits for sideload/QA builds (Play uses .aab natively).
    splits {
        abi {
            isEnable = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
