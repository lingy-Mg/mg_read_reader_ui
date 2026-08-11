#include "novel_reader_ui_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace novel_reader_ui {

void NovelReaderUiPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "novel_reader_ui/system",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<NovelReaderUiPlugin>();
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

NovelReaderUiPlugin::NovelReaderUiPlugin() = default;

NovelReaderUiPlugin::~NovelReaderUiPlugin() {
  if (keep_screen_on_) {
    SetThreadExecutionState(ES_CONTINUOUS);
  }
}

void NovelReaderUiPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() != "setKeepScreenOn") {
    result->NotImplemented();
    return;
  }

  const auto* enabled = std::get_if<bool>(method_call.arguments());
  if (enabled == nullptr) {
    result->Error("invalid_argument", "A boolean value is required.");
    return;
  }

  const EXECUTION_STATE state =
      *enabled ? static_cast<EXECUTION_STATE>(ES_CONTINUOUS | ES_DISPLAY_REQUIRED)
               : ES_CONTINUOUS;
  if (SetThreadExecutionState(state) == 0) {
    result->Error("system_error", "SetThreadExecutionState failed.");
    return;
  }

  keep_screen_on_ = *enabled;
  result->Success();
}

}  // namespace novel_reader_ui
