# ProGuard / R8 rules for sese_hub
#
# Flutter communicates via JNI method calls by name; preserve all classes that
# R8 would otherwise strip due to apparent lack of references.

# ── Flutter engine ────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# ── Firebase (Firestore, Auth, Storage, Functions, Messaging) ─────────────────
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

-keep @com.google.firebase.firestore.annotation.Keep class * { *; }

# ── Kotlin Coroutines ─────────────────────────────────────────────────────────
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}

# ── Serialisation / Reflection ────────────────────────────────────────────────
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# ── image_picker / camera_android ─────────────────────────────────────────────
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# ── permission_handler ────────────────────────────────────────────────────────
-keep class com.baseflow.permissionhandler.** { *; }

# ── Desugar library ───────────────────────────────────────────────────────────
-keep class j$.** { *; }
-dontwarn j$.**
