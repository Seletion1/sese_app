package com.sesetech.sese_hub

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        pinAppCheckDebugToken()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

    private fun pinAppCheckDebugToken(customToken: String? = null) {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val tokenToPin = customToken ?: PINNED_DEBUG_TOKEN
        val secretKey = "com.google.firebase.appcheck.debug.DEBUG_SECRET"

        // 1. Write directly to default SharedPreferences store
        val storeNames = listOf(
            "com.google.firebase.appcheck.debug.store.[DEFAULT]",
            "com.google.firebase.appcheck.debug.store.1:618721373016:android:3e02049c0d164ca650932d"
        )
        storeNames.forEach { name ->
            try {
                val prefs = getSharedPreferences(name, Context.MODE_PRIVATE)
                if (prefs.getString(secretKey, null) != tokenToPin) {
                    prefs.edit().putString(secretKey, tokenToPin).apply()
                }
            } catch (_: Exception) {}
        }

        // 2. Also try dynamic FirebaseApp persistenceKey if initialized
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
        const val APP_CHECK_CHANNEL = "com.sesetech.sese_hub/app_check"
        // Mirrors AppCheckConfig.seseHubDebugToken in sese_core.
        const val PINNED_DEBUG_TOKEN = "e1d8dc46-7c7d-48da-a9fd-e34592249fc5"
    }
}
