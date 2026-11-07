pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            val localProps = file("local.properties")
            if (localProps.exists()) {
                localProps.inputStream().use { properties.load(it) }
            }
            properties.getProperty("flutter.sdk") ?: "/Users/micheal/flutter"
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

rootProject.name = "sese_app"

includeBuild("sese_ride/android") {
    name = "sese_ride"
}
includeBuild("sese_hub/android") {
    name = "sese_hub"
}
