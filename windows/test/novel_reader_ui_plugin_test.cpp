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

TEST(NovelReaderUiPlugin, RejectsInvalidKeepScreenOnArgument) {
  NovelReaderUiPlugin plugin;
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("setKeepScreenOn",
                 std::make_unique<EncodableValue>("invalid")),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string& message,
                        const EncodableValue* details) { error_code = code; },
          nullptr));
  EXPECT_EQ(error_code, "invalid_argument");
}

}  // namespace test
}  // namespace novel_reader_ui
