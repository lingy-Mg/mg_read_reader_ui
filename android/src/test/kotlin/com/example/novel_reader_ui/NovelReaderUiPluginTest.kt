package com.example.novel_reader_ui

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class NovelReaderUiPluginTest {
    @Test
    fun onMethodCall_withInvalidKeepAwakeArgument_returnsError() {
        val plugin = NovelReaderUiPlugin()
        val call = MethodCall("setKeepScreenOn", "invalid")
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)
        Mockito.verify(mockResult).error(
            Mockito.eq("invalid_argument"),
            Mockito.anyString(),
            Mockito.isNull(),
        )
    }
}
