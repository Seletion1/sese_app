package com.sesetech.sese_ride

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

// Maps render 100% with OpenStreetMap raster tiles via flutter_map — no
// Google Maps SDK, no API key, no renderer pinning needed on this Activity.
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        pinAppCheckDebugToken()
        super.onCreate(savedInstanceState)
    }

    /**
     * Pins the Firebase App Check debug secret for sese_ride to [PINNED_DEBUG_TOKEN]
     * so every debug build/install reuses the same token registered in the
     * Firebase console (App Check > Apps > Manage debug tokens).
     *
     * - Runs on debuggable builds ONLY; release builds are untouched.
     * - Uses reflection so nothing breaks when Firebase / App Check is not
     *   integrated yet; it simply no-ops until firebase-appcheck-debug is added.
     * - Must run before the first App Check token fetch (Dart Firebase init),
     *   which is guaranteed here since Activity.onCreate precedes the engine.
     *
     * WARNING: internal SharedPreferences keys of the App Check SDK. If a future
     * SDK version changes them, update the constants below.
     */
    private fun pinAppCheckDebugToken() {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        try {
            val firebaseAppClass = Class.forName("com.google.firebase.FirebaseApp")
            val app = firebaseAppClass.getMethod("getInstance").invoke(null)
            val persistenceKey =
                firebaseAppClass.getMethod("getPersistenceKey").invoke(app) as String
            val prefs = getSharedPreferences(
                "com.google.firebase.appcheck.debug.store.$persistenceKey",
                Context.MODE_PRIVATE,
            )
            val secretKey = "com.google.firebase.appcheck.debug.DEBUG_SECRET"
            if (prefs.getString(secretKey, null) != PINNED_DEBUG_TOKEN) {
                prefs.edit().putString(secretKey, PINNED_DEBUG_TOKEN).apply()
            }
        } catch (_: Exception) {
            // Firebase / App Check not on the classpath yet — skip silently.
        }
    }

    companion object {
        const val TAG = "sese_ride"
        // Mirrors AppCheckConfig.seseRideDebugToken in sese_core.
        const val PINNED_DEBUG_TOKEN = "cba5fa66-ef47-4b2f-83c1-4f05d2f035ad"
    }
}
