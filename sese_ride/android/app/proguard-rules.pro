# ProGuard / R8 rules for sese_ride
#
# Flutter and the Dart AoT engine are compiled to native code and need no rules
# for their own classes. The rules below preserve reflection-dependent runtime
# classes that R8 would otherwise strip.

# ── Flutter engine ────────────────────────────────────────────────────────────
# Flutter communicates via JNI method calls by name; these must survive R8.
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# ── Firebase (Firestore, Auth, Storage, Functions, Messaging) ─────────────────
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Firebase Firestore uses reflection to deserialize documents into Map objects;
# keep all classes annotated with @Keep.
-keep @com.google.firebase.firestore.annotation.Keep class * { *; }

# ── Kotlin Coroutines ─────────────────────────────────────────────────────────
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}

# ── Serialisation / Reflection ────────────────────────────────────────────────
# Keep data classes that go through Gson / JSON-based serialisation at runtime.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# ── image_picker / camera_android / geolocator ────────────────────────────────
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**
-keep class com.baseflow.geolocator.** { *; }

# ── audioplayers / just_audio ─────────────────────────────────────────────────
-keep class xyz.luan.audioplayers.** { *; }
-keep class com.ryanheise.** { *; }

# ── permission_handler ────────────────────────────────────────────────────────
-keep class com.baseflow.permissionhandler.** { *; }

# ── flutter_map (OpenStreetMap tiles — no native SDK needed) ──────────────────
# flutter_map is pure Dart; no native proguard rules needed.

# ── Desugar library ───────────────────────────────────────────────────────────
-keep class j$.** { *; }
-dontwarn j$.**
