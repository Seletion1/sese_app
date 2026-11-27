package com.sesetech.sese_ride

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Handles background notification actions (e.g. "Reject" on an incoming call
 * banner) without launching MainActivity.
 */
class CallActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_REJECT_CALL) return

        val callId = intent.getStringExtra(MainActivity.EXTRA_CALL_ID)?.trim().orEmpty()
        val notificationId = intent.getIntExtra(
            EXTRA_NOTIFICATION_ID,
            SeseFirebaseMessagingService.CALL_NOTIFICATION_ID_BASE,
        )

        val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        mgr?.cancel(notificationId)

        if (callId.isEmpty()) return

        val pendingResult = goAsync()
        try {
            val fsClass = Class.forName("com.google.firebase.firestore.FirebaseFirestore")
            val fs = fsClass.getMethod("getInstance").invoke(null)
            val callsCol = fsClass.getMethod("collection", String::class.java).invoke(fs, "calls")
            val callDoc = callsCol.javaClass.getMethod("document", String::class.java).invoke(callsCol, callId)
            val fieldValueClass = Class.forName("com.google.firebase.firestore.FieldValue")
            val serverTs = fieldValueClass.getMethod("serverTimestamp").invoke(null)

            val updatePayload = hashMapOf<String, Any>(
                "status" to "rejected",
                "endReason" to "declined_from_notification",
                "endedAt" to serverTs,
                "updatedAt" to serverTs,
            )

            val task = callDoc.javaClass
                .getMethod("update", Map::class.java)
                .invoke(callDoc, updatePayload)

            val onCompleteListenerClass = Class.forName("com.google.android.gms.tasks.OnCompleteListener")
            val proxy = java.lang.reflect.Proxy.newProxyInstance(
                context.classLoader,
                arrayOf(onCompleteListenerClass),
            ) { _, _, _ ->
                pendingResult.finish()
                null
            }
            task.javaClass
                .getMethod("addOnCompleteListener", onCompleteListenerClass)
                .invoke(task, proxy)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to reject call $callId from notification: ${e.message}")
            pendingResult.finish()
        }
    }

    companion object {
        private const val TAG = "CallActionReceiver"
        const val ACTION_REJECT_CALL = "com.sesetech.sese_ride.ACTION_REJECT_CALL"
        const val EXTRA_NOTIFICATION_ID = "sese_call_notification_id"
    }
}
