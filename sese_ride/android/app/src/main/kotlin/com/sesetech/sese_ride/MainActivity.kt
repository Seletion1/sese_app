package com.sesetech.sese_ride

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import android.view.WindowManager

class MainActivity : FlutterActivity() {

    private var driverWakeChannel: MethodChannel? = null
    private var pendingWakeOrder: Map<String, String>? = null
    private var pendingCallAction: Map<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pinAppCheckDebugToken()
        configureLockScreenFlags()
        wakeScreen()
        captureWakeIntent(intent)
        captureCallIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        setAppInForeground(true)
    }

    override fun onStop() {
        setAppInForeground(false)
        super.onStop()
    }

    private fun setAppInForeground(inForeground: Boolean) {
        val prefs = getSharedPreferences(
            SeseLocationForegroundService.PREFS_NAME,
            Context.MODE_PRIVATE,
        )
        prefs.edit()
            .putBoolean(FloatingBubbleService.KEY_APP_IN_FOREGROUND, inForeground)
            .apply()
        FloatingBubbleService.syncFromPrefs(applicationContext)
    }

    private fun captureWakeIntent(incomingIntent: Intent?) {
        val orderId = incomingIntent?.getStringExtra(EXTRA_WAKE_ORDER_ID)?.trim().orEmpty()
        if (orderId.isEmpty()) return
        val type = incomingIntent?.getStringExtra(EXTRA_WAKE_TYPE)?.trim().orEmpty().ifEmpty { "incoming_order" }
        val payload = mapOf("orderId" to orderId, "type" to type)
        pendingWakeOrder = payload
        driverWakeChannel?.invokeMethod("onIncomingOrderWake", payload)
    }

    private fun captureCallIntent(incomingIntent: Intent?) {
        val callId = incomingIntent?.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        if (callId.isEmpty()) return
        val notifId = incomingIntent?.getIntExtra(
            CallActionReceiver.EXTRA_NOTIFICATION_ID,
            SeseFirebaseMessagingService.CALL_NOTIFICATION_ID_BASE + (callId.hashCode() and 0x0FFF),
        ) ?: (SeseFirebaseMessagingService.CALL_NOTIFICATION_ID_BASE + (callId.hashCode() and 0x0FFF))
        (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(notifId)

        val payload = mapOf(
            "callId" to callId,
            "action" to (incomingIntent?.getStringExtra(EXTRA_CALL_ACTION)?.trim().orEmpty().ifEmpty { "open" }),
            "callerId" to (incomingIntent?.getStringExtra(EXTRA_CALLER_ID)?.trim().orEmpty()),
            "callerName" to (incomingIntent?.getStringExtra(EXTRA_CALLER_NAME)?.trim().orEmpty().ifEmpty { "Caller" }),
            "callerAvatar" to (incomingIntent?.getStringExtra(EXTRA_CALLER_AVATAR)?.trim().orEmpty()),
        )
        pendingCallAction = payload
        driverWakeChannel?.invokeMethod("onIncomingCallAction", payload)
    }

    private fun configureLockScreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? android.app.KeyguardManager
            keyguardManager?.requestDismissKeyguard(this, null)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
    }

    private fun wakeScreen() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            @Suppress("DEPRECATION")
            val wakeLock = powerManager?.newWakeLock(
                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "sese:OrderWakeLock"
            )
            wakeLock?.acquire(3000)
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MAP_CREDENTIALS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "injectGoogleMapsApiKey", "setGoogleMapsApiKey" -> {
                    val key = call.argument<String>("apiKey")
                    if (!key.isNullOrBlank()) {
                        try {
                            val appInfo = packageManager.getApplicationInfo(packageName, android.content.pm.PackageManager.GET_META_DATA)
                            if (appInfo.metaData == null) {
                                appInfo.metaData = Bundle()
                            }
                            appInfo.metaData.putString("com.google.android.geo.API_KEY", key)
                            try {
                                val mapsInitClass = Class.forName("com.google.android.gms.maps.MapsInitializer")
                                mapsInitClass.getMethod("initialize", Context::class.java).invoke(null, applicationContext)
                            } catch (_: Exception) {}
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MAPS_KEY_ERROR", e.message, null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "initializeMapbox", "setMapboxToken" -> {
                    // Mapbox options / token injection handler
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        driverWakeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DRIVER_WAKE_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialWakeOrder" -> {
                        val payload = pendingWakeOrder
                        pendingWakeOrder = null
                        result.success(payload)
                    }
                    "getInitialCallAction" -> {
                        val payload = pendingCallAction
                        pendingCallAction = null
                        result.success(payload)
                    }
                    "canUseFullScreenIntent" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                            result.success(mgr?.canUseFullScreenIntent() ?: true)
                        } else {
                            result.success(true)
                        }
                    }
                    "openFullScreenIntentSettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName"),
                                ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                                startActivity(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                            result.success(pm?.isIgnoringBatteryOptimizations(packageName) ?: true)
                        } else {
                            result.success(true)
                        }
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                                startActivity(intent)
                            }
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "syncDriverServiceState" -> {
                        val isOnline = call.argument<Boolean>("isOnline") ?: false
                        val hasActiveTrip = call.argument<Boolean>("hasActiveTrip") ?: false
                        val driverUid = call.argument<String>("driverUid") ?: ""
                        val activeTripId = call.argument<String>("activeTripId") ?: ""
                        val prefs = getSharedPreferences(
                            SeseLocationForegroundService.PREFS_NAME,
                            Context.MODE_PRIVATE,
                        )
                        prefs.edit()
                            .putBoolean(SeseLocationForegroundService.KEY_IS_ONLINE, isOnline)
                            .putBoolean(SeseLocationForegroundService.KEY_HAS_ACTIVE_TRIP, hasActiveTrip)
                            .putString(SeseLocationForegroundService.KEY_DRIVER_UID, driverUid)
                            .putString(SeseLocationForegroundService.KEY_ACTIVE_TRIP_ID, activeTripId)
                            .apply()
                        SeseLocationForegroundService.startOrStopFromPrefs(applicationContext)
                        FloatingBubbleService.syncFromPrefs(applicationContext)
                        result.success(true)
                    }
                    "clearDriverSessionState" -> {
                        val prefs = getSharedPreferences(
                            SeseLocationForegroundService.PREFS_NAME,
                            Context.MODE_PRIVATE,
                        )
                        prefs.edit().clear().apply()
                        SeseLocationForegroundService.startOrStopFromPrefs(applicationContext)
                        FloatingBubbleService.hide(applicationContext)
                        result.success(true)
                    }
                    "canDrawOverlays" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            result.success(Settings.canDrawOverlays(this))
                        } else {
                            result.success(true)
                        }
                    }
                    "openOverlaySettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName"),
                                ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                                startActivity(intent)
                            }
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "setBubbleEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        val prefs = getSharedPreferences(
                            SeseLocationForegroundService.PREFS_NAME,
                            Context.MODE_PRIVATE,
                        )
                        prefs.edit()
                            .putBoolean(FloatingBubbleService.KEY_BUBBLE_ENABLED, enabled)
                            .apply()
                        FloatingBubbleService.syncFromPrefs(applicationContext)
                        result.success(true)
                    }
                    "showFloatingBubble" -> {
                        FloatingBubbleService.syncFromPrefs(applicationContext)
                        result.success(true)
                    }
                    "hideFloatingBubble" -> {
                        FloatingBubbleService.hide(applicationContext)
                        result.success(true)
                    }
                    "bringAppToForeground" -> {
                        try {
                            configureLockScreenFlags()
                            wakeScreen()
                            FloatingBubbleService.hide(applicationContext)
                            val launchIntent = Intent(this, MainActivity::class.java).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                            }
                            startActivity(launchIntent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    // singleTask / singleTop delivery: notification/fullScreenIntent deliveries that resolve to the
    // existing MainActivity arrive here instead of recreating it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        configureLockScreenFlags()
        wakeScreen()
        captureWakeIntent(intent)
        captureCallIntent(intent)
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
            true // Fail open so standard Android builds render Google Maps natively
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
        const val GMS_CHANNEL = "com.sesetech.sese_ride/gms_availability"
        const val APP_CHECK_CHANNEL = "com.sesetech.sese_ride/app_check"
        const val MAP_CREDENTIALS_CHANNEL = "com.sesetech.sese_ride/map_credentials"
        const val DRIVER_WAKE_CHANNEL = "com.sesetech.sese_ride/driver_wake"
        const val EXTRA_WAKE_ORDER_ID = "sese_wake_order_id"
        const val EXTRA_WAKE_TYPE = "sese_wake_type"
        const val EXTRA_CALL_ID = "sese_call_id"
        const val EXTRA_CALL_ACTION = "sese_call_action"
        const val EXTRA_CALLER_ID = "sese_caller_id"
        const val EXTRA_CALLER_NAME = "sese_caller_name"
        const val EXTRA_CALLER_AVATAR = "sese_caller_avatar"
        const val PINNED_DEBUG_TOKEN = "cba5fa66-ef47-4b2f-83c1-4f05d2f035ad"
    }
}

