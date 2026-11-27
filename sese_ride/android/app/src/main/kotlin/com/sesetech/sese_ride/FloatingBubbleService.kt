package com.sesetech.sese_ride

import android.animation.ValueAnimator
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import kotlin.math.abs

/**
 * Native Android floating quick-return bubble for online drivers.
 *
 * Lifecycle rules:
 * - Shown ONLY when `isDriverOnline == true` (or `hasActiveTrip == true`),
 *   `driverUid` is non-empty, `bubbleEnabled == true`, the app is NOT in the
 *   foreground, and `Settings.canDrawOverlays` is granted.
 * - Immediately removed when the driver returns to the foreground, goes offline,
 *   or signs out.
 * - Supports smooth dragging and snaps cleanly to the nearest horizontal edge.
 * - Tapping the bubble brings [MainActivity] immediately to the foreground.
 */
class FloatingBubbleService : Service() {

    private var windowManager: WindowManager? = null
    private var bubbleView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var isBubbleAttached = false
    private var edgeAnimator: ValueAnimator? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HIDE) {
            removeBubble()
            stopSelf()
            return START_NOT_STICKY
        }

        if (!shouldShowBubble(this)) {
            removeBubble()
            stopSelf()
            return START_NOT_STICKY
        }

        showBubble()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        removeBubble()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showBubble() {
        if (isBubbleAttached && bubbleView != null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            return
        }

        val wm = windowManager ?: return
        val density = resources.displayMetrics.density
        val sizePx = (BUBBLE_SIZE_DP * density).toInt()
        val marginPx = (EDGE_MARGIN_DP * density).toInt()
        val screenWidth = resources.displayMetrics.widthPixels
        val screenHeight = resources.displayMetrics.heightPixels

        val container = FrameLayout(this).apply {
            val bg = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#111111"))
                setStroke((3 * density).toInt(), Color.WHITE)
            }
            background = bg
            elevation = 8 * density
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
        }

        val iconView = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            scaleType = ImageView.ScaleType.CENTER_CROP
            val pad = (4 * density).toInt()
            setPadding(pad, pad, pad, pad)
        }
        container.addView(
            iconView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            sizePx,
            sizePx,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = screenWidth - sizePx - marginPx
            y = (screenHeight * 0.34f).toInt()
        }

        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f
        var isDragging = false

        container.setOnTouchListener { _, event ->
            val currentParams = layoutParams ?: return@setOnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    edgeAnimator?.cancel()
                    initialX = currentParams.x
                    initialY = currentParams.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - initialTouchX).toInt()
                    val dy = (event.rawY - initialTouchY).toInt()
                    if (!isDragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        isDragging = true
                    }
                    if (isDragging) {
                        currentParams.x = (initialX + dx).coerceIn(0, screenWidth - sizePx)
                        currentParams.y = (initialY + dy).coerceIn(
                            (24 * density).toInt(),
                            screenHeight - sizePx - (48 * density).toInt(),
                        )
                        try {
                            if (isBubbleAttached) {
                                wm.updateViewLayout(container, currentParams)
                            }
                        } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!isDragging) {
                        launchMainActivity()
                    } else {
                        snapToNearestEdge(wm, container, currentParams, screenWidth, sizePx, marginPx)
                    }
                    true
                }
                else -> false
            }
        }

        try {
            wm.addView(container, params)
            bubbleView = container
            layoutParams = params
            isBubbleAttached = true
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot add floating bubble (overlay permission missing): ${e.message}")
            isBubbleAttached = false
            stopSelf()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to add floating bubble: ${e.message}")
            isBubbleAttached = false
            stopSelf()
        }
    }

    private fun snapToNearestEdge(
        wm: WindowManager,
        view: View,
        params: WindowManager.LayoutParams,
        screenWidth: Int,
        sizePx: Int,
        marginPx: Int,
    ) {
        val centerX = params.x + sizePx / 2
        val targetX = if (centerX < screenWidth / 2) {
            marginPx
        } else {
            screenWidth - sizePx - marginPx
        }
        edgeAnimator?.cancel()
        edgeAnimator = ValueAnimator.ofInt(params.x, targetX).apply {
            duration = 220L
            interpolator = DecelerateInterpolator()
            addUpdateListener { anim ->
                params.x = anim.animatedValue as Int
                try {
                    if (isBubbleAttached) {
                        wm.updateViewLayout(view, params)
                    }
                } catch (_: Exception) {}
            }
            start()
        }
    }

    private fun launchMainActivity() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to bring MainActivity to front: ${e.message}")
        }
    }

    private fun removeBubble() {
        edgeAnimator?.cancel()
        edgeAnimator = null
        val view = bubbleView
        if (isBubbleAttached && view != null) {
            try {
                windowManager?.removeViewImmediate(view)
            } catch (e: Exception) {
                Log.w(TAG, "removeViewImmediate warning: ${e.message}")
            }
        }
        bubbleView = null
        layoutParams = null
        isBubbleAttached = false
    }

    companion object {
        private const val TAG = "FloatingBubbleSvc"
        private const val BUBBLE_SIZE_DP = 58
        private const val EDGE_MARGIN_DP = 10

        const val ACTION_SYNC = "com.sesetech.sese_ride.ACTION_SYNC_BUBBLE"
        const val ACTION_HIDE = "com.sesetech.sese_ride.ACTION_HIDE_BUBBLE"

        const val KEY_APP_IN_FOREGROUND = "appInForeground"
        const val KEY_BUBBLE_ENABLED = "floatingBubbleEnabled"

        fun shouldShowBubble(context: Context): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(context)) {
                return false
            }
            val prefs = context.getSharedPreferences(
                SeseLocationForegroundService.PREFS_NAME,
                Context.MODE_PRIVATE,
            )
            val isOnline = prefs.getBoolean(SeseLocationForegroundService.KEY_IS_ONLINE, false)
            val hasActiveTrip = prefs.getBoolean(SeseLocationForegroundService.KEY_HAS_ACTIVE_TRIP, false)
            val driverUid = prefs.getString(SeseLocationForegroundService.KEY_DRIVER_UID, "")?.trim().orEmpty()
            val inForeground = prefs.getBoolean(KEY_APP_IN_FOREGROUND, true)
            val bubbleEnabled = prefs.getBoolean(KEY_BUBBLE_ENABLED, true)
            return (isOnline || hasActiveTrip) && driverUid.isNotEmpty() && !inForeground && bubbleEnabled
        }

        fun syncFromPrefs(context: Context) {
            try {
                val intent = Intent(context, FloatingBubbleService::class.java)
                if (shouldShowBubble(context)) {
                    intent.action = ACTION_SYNC
                    context.startService(intent)
                } else {
                    intent.action = ACTION_HIDE
                    context.stopService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "syncFromPrefs warning: ${e.message}")
            }
        }

        fun hide(context: Context) {
            try {
                context.stopService(Intent(context, FloatingBubbleService::class.java))
            } catch (_: Exception) {}
        }
    }
}
