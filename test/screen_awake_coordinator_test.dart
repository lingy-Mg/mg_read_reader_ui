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

  test('immersive mode is independently aggregated and released', () async {
    final ReaderPlatform original = ReaderPlatform.instance;
    final _RecordingPlatform platform = _RecordingPlatform();
    ReaderPlatform.instance = platform;
    final Object holder = Object();
    try {
      await ScreenAwakeCoordinator.instance.acquire(
        holder,
        keepScreenOn: false,
        immersiveMode: true,
      );
      await ScreenAwakeCoordinator.instance.acquire(
        holder,
        keepScreenOn: false,
        immersiveMode: true,
      );
      expect(platform.systemUi, <_SystemUi>[const _SystemUi(false, true)]);
      await ScreenAwakeCoordinator.instance.release(holder);
      expect(platform.systemUi, <_SystemUi>[
        const _SystemUi(false, true),
        const _SystemUi(false, false),
      ]);
    } finally {
      await ScreenAwakeCoordinator.instance.release(holder);
      ReaderPlatform.instance = original;
    }
  });
}

class _RecordingPlatform extends ReaderPlatform
    with MockPlatformInterfaceMixin {
  final List<bool> values = <bool>[];
  final List<_SystemUi> systemUi = <_SystemUi>[];

  @override
  Future<void> setReaderSystemUi({
    required bool keepScreenOn,
    required bool immersiveMode,
  }) async {
    values.add(keepScreenOn);
    systemUi.add(_SystemUi(keepScreenOn, immersiveMode));
  }
}

class _SystemUi {
  const _SystemUi(this.keepScreenOn, this.immersiveMode);
  final bool keepScreenOn;
  final bool immersiveMode;
  @override
  bool operator ==(Object other) =>
      other is _SystemUi &&
      keepScreenOn == other.keepScreenOn &&
      immersiveMode == other.immersiveMode;
  @override
  int get hashCode => Object.hash(keepScreenOn, immersiveMode);
}
