package com.sesetech.sese_ride

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterPlugin for `com.sesetech.sese_ride/app_launcher`.
 *
 * Automatically attached to all FlutterEngines (including background
 * OverlayService engines) so that calling `bringToForeground` from any
 * isolate or overlay window reliably opens/restores `MainActivity`.
 */
class AppLauncherPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var applicationContext: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "bringToForeground" -> {
                val ctx = applicationContext
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
                            val fallbackIntent = Intent(ctx, MainActivity::class.java).apply {
                                action = Intent.ACTION_MAIN
                                addCategory(Intent.CATEGORY_LAUNCHER)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                            }
                            ctx.startActivity(fallbackIntent)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("LAUNCH_ERROR", e.message, null)
                    }
                } else {
                    result.error("NO_CONTEXT", "Application context is null", null)
                }
            }
            "moveTaskToBack" -> {
                // Background activity cannot directly move task to back, but method succeeds safely
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "com.sesetech.sese_ride/app_launcher"
    }
}
