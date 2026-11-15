package com.sesetech.sese_ride.app_launcher

import android.app.Activity
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * AppLauncherPlugin
 *
 * Automatically registered via Flutter's GeneratedPluginRegistrant on all FlutterEngines,
 * including background OverlayService engines.
 */
class AppLauncherPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private var context: Context? = null
    private var activity: Activity? = null
    private var channelPrimary: MethodChannel? = null
    private var channelFallback: MethodChannel? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channelPrimary = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_PRIMARY).apply {
            setMethodCallHandler(this@AppLauncherPlugin)
        }
        channelFallback = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_FALLBACK).apply {
            setMethodCallHandler(this@AppLauncherPlugin)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channelPrimary?.setMethodCallHandler(null)
        channelPrimary = null
        channelFallback?.setMethodCallHandler(null)
        channelFallback = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "bringToForeground" -> {
                val ctx = activity ?: context
                if (ctx != null) {
                    try {
                        // Wake device screen if sleeping so full screen is visible immediately
                        try {
                            val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
                            @Suppress("DEPRECATION")
                            val wakeLock = powerManager?.newWakeLock(
                                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                                android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP,
                                "sese:OrderWakeLock"
                            )
                            wakeLock?.acquire(3000)
                        } catch (_: Exception) {}

                        // 1. Move existing app task to front via ActivityManager
                        try {
                            val activityManager = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
                            val appTasks = activityManager?.appTasks
                            if (!appTasks.isNullOrEmpty()) {
                                appTasks[0].moveToFront()
                            }
                        } catch (_: Exception) {}

                        // 2. Launch Intent with NEW_TASK + RESET_TASK_IF_NEEDED + REORDER_TO_FRONT
                        val launchIntent = (ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                            ?: Intent(ctx, Class.forName("${ctx.packageName}.MainActivity"))).apply {
                            action = Intent.ACTION_MAIN
                            addCategory(Intent.CATEGORY_LAUNCHER)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                            val extras = call.argument<Map<String, Any>>("extras")
                            extras?.forEach { (k, v) ->
                                putExtra(k, v.toString())
                            }
                        }
                        try {
                            ctx.startActivity(launchIntent)
                        } catch (_: Exception) {}

                        // 3. PendingIntent with background activity start mode
                        try {
                            val pendingIntent = android.app.PendingIntent.getActivity(
                                ctx,
                                0,
                                launchIntent,
                                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                            )
                            if (android.os.Build.VERSION.SDK_INT >= 34) {
                                val options = android.app.ActivityOptions.makeBasic()
                                options.setPendingIntentBackgroundActivityStartMode(
                                    android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                                )
                                pendingIntent.send(ctx, 0, null, null, null, null, options.toBundle())
                            } else {
                                pendingIntent.send()
                            }
                        } catch (_: Exception) {}

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LAUNCH_ERROR", e.message, null)
                    }
                } else {
                    result.error("NO_CONTEXT", "Application context is null", null)
                }
            }
            "canDrawOverlays" -> {
                val ctx = activity ?: context
                if (ctx != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                    result.success(android.provider.Settings.canDrawOverlays(ctx))
                } else {
                    result.success(true)
                }
            }
            "requestOverlayPermission" -> {
                val ctx = activity ?: context
                if (ctx != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                    try {
                        val intent = Intent(
                            android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            android.net.Uri.parse("package:${ctx.packageName}")
                        ).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        ctx.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PERMISSION_ERROR", e.message, null)
                    }
                } else {
                    result.success(true)
                }
            }
            "moveTaskToBack" -> {
                val act = activity
                if (act != null) {
                    val moved = act.moveTaskToBack(true)
                    result.success(moved)
                } else {
                    result.success(false)
                }
            }
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            else -> result.notImplemented()
        }
    }

    // ActivityAware lifecycle
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    companion object {
        const val CHANNEL_PRIMARY = "com.sesetech.sese_ride/app_launcher"
        const val CHANNEL_FALLBACK = "app_launcher"
    }
}
