package com.sesetech.sese_ride

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Persistent Foreground Service (`location`) for SeSe Ride.
 *
 * - Runs ONLY while `isDriverOnline == true` or `hasActiveTrip == true` in
 *   SharedPreferences (`sese_driver_state`).
 * - Uses `START_STICKY` and schedules an AlarmManager restart in `onTaskRemoved`
 *   only when active, so swiping from Recents does not kill live tracking or
 *   dispatch reception.
 * - Stops cleanly when the driver goes offline and has no active trip.
 */
class SeseLocationForegroundService : Service(), LocationListener {

    private var locationManager: LocationManager? = null
    private var lastSyncedTimeMs: Long = 0L
    private var lastSyncedLat: Double? = null
    private var lastSyncedLng: Double? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopTracking()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val isOnline = prefs.getBoolean(KEY_IS_ONLINE, false)
        val hasActiveTrip = prefs.getBoolean(KEY_HAS_ACTIVE_TRIP, false)

        if (!isOnline && !hasActiveTrip) {
            stopTracking()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildForegroundNotification(isOnline, hasActiveTrip)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        startLocationUpdates()
        return START_STICKY
    }

    override fun onDestroy() {
        stopTracking()
        FloatingBubbleService.hide(applicationContext)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val isOnline = prefs.getBoolean(KEY_IS_ONLINE, false)
        val hasActiveTrip = prefs.getBoolean(KEY_HAS_ACTIVE_TRIP, false)
        if (!isOnline && !hasActiveTrip) return

        try {
            val restartIntent = Intent(applicationContext, SeseServiceRestartReceiver::class.java)
            val pendingIntent = PendingIntent.getBroadcast(
                applicationContext,
                RESTART_REQUEST_CODE,
                restartIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            alarmManager?.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + 1500L,
                pendingIntent,
            )
        } catch (e: Exception) {
            Log.w(TAG, "onTaskRemoved restart schedule failed: ${e.message}")
        }
    }

    private fun startLocationUpdates() {
        val hasFine = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) return

        try {
            val lm = locationManager ?: (getSystemService(Context.LOCATION_SERVICE) as? LocationManager).also {
                locationManager = it
            } ?: return

            lm.removeUpdates(this)
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    MIN_TIME_MS,
                    MIN_DISTANCE_M,
                    this,
                    Looper.getMainLooper(),
                )
            }
            if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    MIN_TIME_MS,
                    MIN_DISTANCE_M,
                    this,
                    Looper.getMainLooper(),
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "startLocationUpdates error: ${e.message}")
        }
    }

    private fun stopTracking() {
        try {
            locationManager?.removeUpdates(this)
        } catch (_: Exception) {}
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onLocationChanged(location: Location) {
        val now = System.currentTimeMillis()
        val lat = location.latitude
        val lng = location.longitude
        if (lat == 0.0 && lng == 0.0) return

        val prevLat = lastSyncedLat
        val prevLng = lastSyncedLng
        var movedEnough = prevLat == null || prevLng == null
        if (!movedEnough && prevLat != null && prevLng != null) {
            val results = FloatArray(1)
            Location.distanceBetween(prevLat, prevLng, lat, lng, results)
            movedEnough = results[0] >= 15f
        }
        if (!movedEnough && (now - lastSyncedTimeMs) < 8000L) {
            return
        }
        lastSyncedTimeMs = now
        lastSyncedLat = lat
        lastSyncedLng = lng

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putFloat(KEY_LAST_LAT, lat.toFloat())
            .putFloat(KEY_LAST_LNG, lng.toFloat())
            .putLong(KEY_LAST_LOC_MS, now)
            .apply()

        val isOnline = prefs.getBoolean(KEY_IS_ONLINE, false)
        val activeTripId = prefs.getString(KEY_ACTIVE_TRIP_ID, "")?.trim().orEmpty()
        syncLocationToFirestoreBestEffort(lat, lng, now, isOnline, activeTripId)
    }

    @Deprecated("Deprecated in Android API 29")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}

    /**
     * Best-effort authenticated Firestore mirror using reflection so no extra
     * Android Gradle dependency is required beyond FlutterFire plugins.
     */
    private fun syncLocationToFirestoreBestEffort(
        lat: Double,
        lng: Double,
        nowMs: Long,
        isOnline: Boolean,
        activeTripId: String,
    ) {
        try {
            val authClass = Class.forName("com.google.firebase.auth.FirebaseAuth")
            val auth = authClass.getMethod("getInstance").invoke(null)
            val currentUser = authClass.getMethod("getCurrentUser").invoke(auth) ?: return
            val uid = currentUser.javaClass.getMethod("getUid").invoke(currentUser) as? String
            if (uid.isNullOrBlank()) return

            val fsClass = Class.forName("com.google.firebase.firestore.FirebaseFirestore")
            val fs = fsClass.getMethod("getInstance").invoke(null)
            val setOptionsClass = Class.forName("com.google.firebase.firestore.SetOptions")
            val mergeOpt = setOptionsClass.getMethod("merge").invoke(null)

            val locMap = hashMapOf<String, Any>(
                "lat" to lat,
                "lng" to lng,
                "updatedAt" to nowMs,
            )

            if (isOnline) {
                val driversCol = fsClass.getMethod("collection", String::class.java).invoke(fs, "drivers")
                val driverDoc = driversCol.javaClass.getMethod("doc", String::class.java).invoke(driversCol, uid)
                val driverPayload = hashMapOf<String, Any>(
                    "lastLocation" to locMap,
                    "latitude" to lat,
                    "longitude" to lng,
                )
                driverDoc.javaClass
                    .getMethod("set", Any::class.java, setOptionsClass)
                    .invoke(driverDoc, driverPayload, mergeOpt)
            }

            if (activeTripId.isNotEmpty()) {
                val tripsCol = fsClass.getMethod("collection", String::class.java).invoke(fs, "trips")
                val tripDoc = tripsCol.javaClass.getMethod("doc", String::class.java).invoke(tripsCol, activeTripId)
                val tripPayload = hashMapOf<String, Any>(
                    "driverLocation" to locMap,
                )
                tripDoc.javaClass
                    .getMethod("set", Any::class.java, setOptionsClass)
                    .invoke(tripDoc, tripPayload, mergeOpt)
            }
        } catch (_: Exception) {
            // Non-fatal: Flutter foreground/background isolate or callable handles sync when active.
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Live Location & Dispatch",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps live GPS tracking and incoming order dispatch active."
                    setShowBadge(false)
                }
                mgr.createNotificationChannel(channel)
            }
        }
    }

    private fun buildForegroundNotification(isOnline: Boolean, hasActiveTrip: Boolean): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val subtitle = when {
            hasActiveTrip -> "Active trip live GPS tracking enabled"
            isOnline -> "Live location & dispatch enabled"
            else -> "SeSe Ride is active"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("SeSe Ride is active")
            .setContentText(subtitle)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .build()
    }

    companion object {
        private const val TAG = "SeseLocationFGS"
        const val CHANNEL_ID = "sese_location_tracking"
        const val NOTIFICATION_ID = 41002
        const val RESTART_REQUEST_CODE = 41003
        const val ACTION_START = "com.sesetech.sese_ride.ACTION_START_LOCATION_FGS"
        const val ACTION_STOP = "com.sesetech.sese_ride.ACTION_STOP_LOCATION_FGS"

        const val PREFS_NAME = "sese_driver_state"
        const val KEY_IS_ONLINE = "isDriverOnline"
        const val KEY_HAS_ACTIVE_TRIP = "hasActiveTrip"
        const val KEY_DRIVER_UID = "driverUid"
        const val KEY_ACTIVE_TRIP_ID = "activeTripId"
        const val KEY_LAST_LAT = "lastBgLat"
        const val KEY_LAST_LNG = "lastBgLng"
        const val KEY_LAST_LOC_MS = "lastBgLocMs"

        private const val MIN_TIME_MS = 5000L
        private const val MIN_DISTANCE_M = 10f

        fun startOrStopFromPrefs(context: Context) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val isOnline = prefs.getBoolean(KEY_IS_ONLINE, false)
            val hasActiveTrip = prefs.getBoolean(KEY_HAS_ACTIVE_TRIP, false)
            val intent = Intent(context, SeseLocationForegroundService::class.java)
            if (isOnline || hasActiveTrip) {
                intent.action = ACTION_START
                ContextCompat.startForegroundService(context, intent)
            } else {
                intent.action = ACTION_STOP
                context.stopService(intent)
            }
        }
    }
}

class SeseServiceRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        SeseLocationForegroundService.startOrStopFromPrefs(context)
    }
}
