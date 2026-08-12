package com.example.novel_reader_ui

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import kotlin.test.assertEquals

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class NovelReaderUiPluginTest {
    @Test
    fun onMethodCall_getCapabilities_returnsSupportedCapabilities() {
        val plugin = NovelReaderUiPlugin()
        val call = MethodCall("getCapabilities", null)
        val result = RecordingResult()

        plugin.onMethodCall(call, result)

        assertEquals(
            mapOf("keepScreenOn" to true, "immersiveMode" to true),
            result.successValue,
        )
    }

    @Test
    fun onMethodCall_withInvalidSystemUiArgument_returnsError() {
        val plugin = NovelReaderUiPlugin()
        val call = MethodCall("setReaderSystemUi", mapOf("keepScreenOn" to true))
        val result = RecordingResult()
        plugin.onMethodCall(call, result)
        assertEquals("invalid_argument", result.errorCode)
    }

    private class RecordingResult : MethodChannel.Result {
        var successValue: Any? = null
        var errorCode: String? = null

        override fun success(result: Any?) {
            successValue = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
        }

        override fun notImplemented() = Unit
    }
}
