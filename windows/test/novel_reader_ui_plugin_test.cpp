#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "novel_reader_ui_plugin.h"

namespace novel_reader_ui {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(NovelReaderUiPlugin, RejectsIncompleteSystemUiArguments) {
  NovelReaderUiPlugin plugin;
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall(
          "setReaderSystemUi",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("keepScreenOn"), EncodableValue(true)},
          })),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string& message,
                        const EncodableValue* details) { error_code = code; },
          nullptr));
  EXPECT_EQ(error_code, "invalid_argument");
}

TEST(NovelReaderUiPlugin, ReportsSystemUiCapabilities) {
  NovelReaderUiPlugin plugin;
  EncodableValue response;
  bool received_success = false;
  plugin.HandleMethodCall(
      MethodCall("getCapabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&response, &received_success](const EncodableValue* value) {
            if (value != nullptr) {
              response = *value;
              received_success = true;
            }
          },
          nullptr, nullptr));
  EXPECT_TRUE(received_success);
  const auto& capabilities = std::get<EncodableMap>(response);
  EXPECT_TRUE(std::get<bool>(capabilities.at(EncodableValue("keepScreenOn"))));
  EXPECT_FALSE(std::get<bool>(capabilities.at(EncodableValue("immersiveMode"))));
}

}  // namespace test
}  // namespace novel_reader_ui
