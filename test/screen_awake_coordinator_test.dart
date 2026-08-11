import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';
import 'package:novel_reader_ui/src/platform/screen_awake_coordinator.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('screen awake is reference counted across reader owners', () async {
    final ReaderPlatform original = ReaderPlatform.instance;
    final _RecordingPlatform platform = _RecordingPlatform();
    ReaderPlatform.instance = platform;
    final Object first = Object();
    final Object second = Object();

    try {
      await ScreenAwakeCoordinator.instance.acquire(first);
      await ScreenAwakeCoordinator.instance.acquire(first);
      await ScreenAwakeCoordinator.instance.acquire(second);
      expect(platform.values, <bool>[true]);

      await ScreenAwakeCoordinator.instance.release(first);
      expect(platform.values, <bool>[true]);

      await ScreenAwakeCoordinator.instance.release(second);
      expect(platform.values, <bool>[true, false]);
      expect(ScreenAwakeCoordinator.instance.holderCount, 0);
    } finally {
      await ScreenAwakeCoordinator.instance.release(first);
      await ScreenAwakeCoordinator.instance.release(second);
      ReaderPlatform.instance = original;
    }
  });
}

class _RecordingPlatform extends ReaderPlatform
    with MockPlatformInterfaceMixin {
  final List<bool> values = <bool>[];

  @override
  Future<void> setKeepScreenOn(bool enabled) async => values.add(enabled);
}
