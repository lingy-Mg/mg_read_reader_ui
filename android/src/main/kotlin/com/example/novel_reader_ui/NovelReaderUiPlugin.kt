package com.example.novel_reader_ui

import android.app.Activity
import android.view.WindowManager
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
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
    private var immersiveMode = false
    private var originalStatusBarsVisible: Boolean? = null
    private var originalNavigationBarsVisible: Boolean? = null
    private var originalSystemUiVisibility: Int? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "novel_reader_ui/system")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(mapOf("keepScreenOn" to true, "immersiveMode" to true))
            "setReaderSystemUi" -> {
                val args = call.arguments as? Map<*, *> ?: run { result.error("invalid_argument", "A settings map is required.", null); return }
                val enabled = args["keepScreenOn"] as? Boolean ?: run { result.error("invalid_argument", "A keepScreenOn boolean is required.", null); return }
                val immersive = args["immersiveMode"] as? Boolean ?: run { result.error("invalid_argument", "An immersiveMode boolean is required.", null); return }
                val currentActivity = activity
                if ((enabled || immersive) && currentActivity == null) {
                    result.error("activity_unavailable", "No Android Activity is attached.", null)
                    return
                }
                keepScreenOn = enabled
                immersiveMode = immersive
                applyKeepScreenOn(currentActivity, enabled)
                applyImmersiveMode(currentActivity, immersive)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (keepScreenOn) applyKeepScreenOn(activity, true)
        if (immersiveMode) applyImmersiveMode(activity, true)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        applyKeepScreenOn(activity, false)
        applyImmersiveMode(activity, false)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (keepScreenOn) applyKeepScreenOn(activity, true)
        if (immersiveMode) applyImmersiveMode(activity, true)
    }

    override fun onDetachedFromActivity() {
        applyKeepScreenOn(activity, false)
        applyImmersiveMode(activity, false)
        activity = null
        keepScreenOn = false
        immersiveMode = false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applyKeepScreenOn(activity, false)
        applyImmersiveMode(activity, false)
        keepScreenOn = false
        immersiveMode = false
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

    private fun applyImmersiveMode(target: Activity?, enabled: Boolean) {
        target ?: return
        target.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                target.window.insetsController?.let { controller ->
                    if (enabled) {
                        if (originalStatusBarsVisible == null) {
                            val insets = target.window.decorView.rootWindowInsets
                            originalStatusBarsVisible = insets?.isVisible(WindowInsets.Type.statusBars()) ?: true
                            originalNavigationBarsVisible = insets?.isVisible(WindowInsets.Type.navigationBars()) ?: true
                        }
                        controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        controller.hide(WindowInsets.Type.systemBars())
                    } else {
                        restoreImmersiveMode(controller)
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                if (enabled) {
                    if (originalSystemUiVisibility == null) originalSystemUiVisibility = target.window.decorView.systemUiVisibility
                    target.window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                } else if (originalSystemUiVisibility != null) {
                    target.window.decorView.systemUiVisibility = originalSystemUiVisibility!!
                    originalSystemUiVisibility = null
                }
            }
        }
    }

    private fun restoreImmersiveMode(controller: WindowInsetsController) {
        when (originalStatusBarsVisible) {
            true -> controller.show(WindowInsets.Type.statusBars())
            false -> controller.hide(WindowInsets.Type.statusBars())
            null -> Unit
        }
        when (originalNavigationBarsVisible) {
            true -> controller.show(WindowInsets.Type.navigationBars())
            false -> controller.hide(WindowInsets.Type.navigationBars())
            null -> Unit
        }
        originalStatusBarsVisible = null
        originalNavigationBarsVisible = null
    }
}
