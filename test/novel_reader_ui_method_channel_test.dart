import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('novel_reader_ui/system');
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('screen awake uses the private system channel', () async {
    final MethodChannelReaderPlatform platform = MethodChannelReaderPlatform();
    await platform.setReaderSystemUi(keepScreenOn: true, immersiveMode: true);
    await platform.setReaderSystemUi(keepScreenOn: false, immersiveMode: false);

    expect(calls.map((call) => call.method), <String>[
      'setReaderSystemUi',
      'setReaderSystemUi',
    ]);
    expect(calls.map((call) => call.arguments), <Map<String, bool>>[
      <String, bool>{'keepScreenOn': true, 'immersiveMode': true},
      <String, bool>{'keepScreenOn': false, 'immersiveMode': false},
    ]);
  });
}
