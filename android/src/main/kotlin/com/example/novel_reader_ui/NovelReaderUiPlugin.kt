package com.example.novel_reader_ui

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Native system support for the novel reader. */
class NovelReaderUiPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var keepScreenOn = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "novel_reader_ui/system")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setKeepScreenOn" -> {
                val enabled = call.arguments as? Boolean
                if (enabled == null) {
                    result.error("invalid_argument", "A boolean value is required.", null)
                    return
                }
                val currentActivity = activity
                if (enabled && currentActivity == null) {
                    result.error("activity_unavailable", "No Android Activity is attached.", null)
                    return
                }
                keepScreenOn = enabled
                applyKeepScreenOn(currentActivity, enabled)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (keepScreenOn) applyKeepScreenOn(activity, true)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        applyKeepScreenOn(activity, false)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (keepScreenOn) applyKeepScreenOn(activity, true)
    }

    override fun onDetachedFromActivity() {
        applyKeepScreenOn(activity, false)
        activity = null
        keepScreenOn = false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applyKeepScreenOn(activity, false)
        keepScreenOn = false
        channel.setMethodCallHandler(null)
    }

    private fun applyKeepScreenOn(target: Activity?, enabled: Boolean) {
        target ?: return
        target.runOnUiThread {
            if (enabled) {
                target.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                target.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }
}
