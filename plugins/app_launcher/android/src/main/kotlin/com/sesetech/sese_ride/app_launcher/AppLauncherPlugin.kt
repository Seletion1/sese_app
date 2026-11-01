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
                        val launchIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
                            addCategory(Intent.CATEGORY_LAUNCHER)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                        }
                        if (launchIntent != null) {
                            ctx.startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.error("NO_LAUNCH_INTENT", "Could not resolve launch intent for ${ctx.packageName}", null)
                        }
                    } catch (e: Exception) {
                        result.error("LAUNCH_ERROR", e.message, null)
                    }
                } else {
                    result.error("NO_CONTEXT", "Application context is null", null)
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
