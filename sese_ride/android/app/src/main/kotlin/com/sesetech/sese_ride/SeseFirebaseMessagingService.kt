package com.sesetech.sese_ride

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * High-priority FCM data-message handler for incoming driver orders.
 *
 * Subclasses [FlutterFirebaseMessagingService] so Flutter's background handler
 * still operates normally while native Android immediately posts a
 * `setFullScreenIntent` notification on `incoming_orders_fullscreen` even when
 * the app is killed or the screen is locked.
 */
class SeseFirebaseMessagingService : FlutterFirebaseMessagingService() {

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val data = remoteMessage.data
        val type = (data["type"] ?: "").trim()

        if (INCOMING_ORDER_TYPES.contains(type)) {
            handleIncomingOrderDataPush(data, type)
        }

        super.onMessageReceived(remoteMessage)
    }

    private fun handleIncomingOrderDataPush(data: Map<String, String>, type: String) {
        val orderId = (data["orderId"] ?: data["tripId"] ?: "").trim()
        if (orderId.isEmpty()) return

        // Reject expired offers so stale pushes never wake the driver
        val expiresAtMs = (data["expiresAtMs"] ?: data["pingExpiresAt"] ?: "").toLongOrNull()
        if (expiresAtMs != null && expiresAtMs > 0L && System.currentTimeMillis() > expiresAtMs) {
            Log.d(TAG, "Ignoring expired incoming order push: $orderId")
            return
        }

        // Verify local session belongs to an active online driver
        val prefs = getSharedPreferences(SeseLocationForegroundService.PREFS_NAME, Context.MODE_PRIVATE)
        val isDriverOnline = prefs.getBoolean(SeseLocationForegroundService.KEY_IS_ONLINE, false)
        val localUid = prefs.getString(SeseLocationForegroundService.KEY_DRIVER_UID, "")?.trim().orEmpty()
        if (!isDriverOnline || localUid.isEmpty()) {
            Log.d(TAG, "Ignoring incoming order push: driver offline or unauthenticated locally.")
            return
        }

        val targetDriverId = (data["targetDriverId"] ?: "").trim()
        if (targetDriverId.isNotEmpty() && targetDriverId != localUid) {
            Log.w(TAG, "Ignoring incoming order push: targetDriverId mismatch.")
            return
        }

        val title = (data["title"] ?: "New Ride Request").trim().ifEmpty { "New Ride Request" }
        val body = (data["body"] ?: "Tap to view pickup & fare details").trim().ifEmpty {
            "Tap to view pickup & fare details"
        }

        postFullScreenOrderNotification(orderId, type, title, body)
    }

    private fun postFullScreenOrderNotification(
        orderId: String,
        type: String,
        title: String,
        body: String,
    ) {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        ensureIncomingOrderChannel(mgr)

        val wakeIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_WAKE_ORDER_ID, orderId)
            putExtra(MainActivity.EXTRA_WAKE_TYPE, type)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            orderId.hashCode(),
            wakeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val canFullScreen = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            mgr.canUseFullScreenIntent()
        } else {
            true
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setTimeoutAfter(45_000L)
            .setContentIntent(pendingIntent)

        if (canFullScreen) {
            builder.setFullScreenIntent(pendingIntent, true)
        }

        val notificationId = NOTIFICATION_ID_BASE + (orderId.hashCode() and 0x0FFF)
        mgr.notify(notificationId, builder.build())

        // If the driver is outside the app and overlay permission is granted,
        // immediately bring MainActivity to the foreground so the incoming order
        // view pops up without requiring a notification tap.
        val prefs = getSharedPreferences(SeseLocationForegroundService.PREFS_NAME, Context.MODE_PRIVATE)
        val inForeground = prefs.getBoolean(FloatingBubbleService.KEY_APP_IN_FOREGROUND, false)
        val hasOverlay = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
        if (!inForeground && hasOverlay) {
            try {
                wakeIntent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                startActivity(wakeIntent)
            } catch (e: Exception) {
                Log.w(TAG, "Immediate order wake startActivity skipped: ${e.message}")
            }
        }
    }

    private fun ensureIncomingOrderChannel(mgr: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            val soundUri = Uri.parse("android.resource://$packageName/raw/sese_alert_chime")
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Incoming Orders (Full-Screen)",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "High-priority incoming trip and delivery requests."
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 250, 500)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(soundUri, attrs)
            }
            mgr.createNotificationChannel(channel)
        }
    }

    companion object {
        private const val TAG = "SeseFcmService"
        const val CHANNEL_ID = "incoming_orders_fullscreen"
        private const val NOTIFICATION_ID_BASE = 52000

        private val INCOMING_ORDER_TYPES = setOf(
            "incoming_order",
            "new_trip_offer",
            "trip_offer",
            "direct_ping",
            "tier_ping",
            "marketplace_broadcast",
        )
    }
}
