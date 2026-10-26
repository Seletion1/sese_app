package com.sesetech.sese_ride

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        pinAppCheckDebugToken()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "bringToForeground") {
                bringAppToForeground()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GMS_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isAvailable") {
                result.success(isGooglePlayServicesAvailable())
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHECK_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "pinDebugToken") {
                val token = call.argument("token") as? String ?: PINNED_DEBUG_TOKEN
                pinAppCheckDebugToken(token)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    // singleTop delivery: notification/bubble taps that resolve to the
    // existing MainActivity arrive here instead of recreating it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    // Restores sese_ride to the foreground (bubble tap + "SeSe Driver
    // Active" notification tap path). REORDER_TO_FRONT reuses the existing
    // singleTop MainActivity instead of stacking a second copy; the unified
    // tray notification's content PendingIntent is built with
    // FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE per Android 12+ requirements.
    private fun bringAppToForeground() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }

    // Reports whether Google Play Services is installed and operational on this device.
    // Used by SeseUniversalMap to verify GMS presence before rendering Google Maps.
    private fun isGooglePlayServicesAvailable(): Boolean {
        return try {
            val apiClass = Class.forName("com.google.android.gms.common.GoogleApiAvailability")
            val instance = apiClass.getMethod("getInstance").invoke(null)
            val code = apiClass.getMethod("isGooglePlayServicesAvailable", Context::class.java)
                .invoke(instance, this) as Int
            code == 0 // ConnectionResult.SUCCESS
        } catch (_: Exception) {
            false
        }
    }

    private fun pinAppCheckDebugToken(customToken: String? = null) {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val tokenToPin = customToken ?: PINNED_DEBUG_TOKEN
        val secretKey = "com.google.firebase.appcheck.debug.DEBUG_SECRET"

        // 1. Write directly to default and app-specific SharedPreferences stores
        val storeNames = listOf(
            "com.google.firebase.appcheck.debug.store.[DEFAULT]",
            "com.google.firebase.appcheck.debug.store.1:618721373016:android:9fb16cb52c1804c550932d"
        )
        storeNames.forEach { name ->
            try {
                val prefs = getSharedPreferences(name, Context.MODE_PRIVATE)
                if (prefs.getString(secretKey, null) != tokenToPin) {
                    prefs.edit().putString(secretKey, tokenToPin).apply()
                }
            } catch (_: Exception) {}
        }

        // 2. Also try dynamic FirebaseApp persistenceKey if Firebase is initialized
        try {
            val firebaseAppClass = Class.forName("com.google.firebase.FirebaseApp")
            val app = firebaseAppClass.getMethod("getInstance").invoke(null)
            val persistenceKey = firebaseAppClass.getMethod("getPersistenceKey").invoke(app) as String
            val prefs = getSharedPreferences(
                "com.google.firebase.appcheck.debug.store.$persistenceKey",
                Context.MODE_PRIVATE,
            )
            if (prefs.getString(secretKey, null) != tokenToPin) {
                prefs.edit().putString(secretKey, tokenToPin).apply()
            }
        } catch (_: Exception) {}
    }

    companion object {
        const val TAG = "sese_ride"
        const val CHANNEL = "com.sesetech.sese_ride/app_launcher"
        const val GMS_CHANNEL = "com.sesetech.sese_ride/gms_availability"
        const val APP_CHECK_CHANNEL = "com.sesetech.sese_ride/app_check"
        const val PINNED_DEBUG_TOKEN = "cba5fa66-ef47-4b2f-83c1-4f05d2f035ad"
    }
}

