import 'dart:async';

import '../api/models.dart';
import 'reader_platform.dart';

class ScreenAwakeCoordinator {
  ScreenAwakeCoordinator._();

  static final ScreenAwakeCoordinator instance = ScreenAwakeCoordinator._();

  final Set<Object> _holders = <Object>{};
  Future<void> _operation = Future<void>.value();

  int get holderCount => _holders.length;

  Future<void> acquire(Object holder) {
    if (!_holders.add(holder)) {
      return _operation;
    }
    if (_holders.length > 1) {
      return _operation;
    }
    return _enqueue(() async {
      try {
        await ReaderPlatform.instance.setKeepScreenOn(true);
      } catch (error) {
        _holders.remove(holder);
        throw ReaderFailure(
          ReaderFailureKind.platform,
          '无法保持屏幕常亮',
          cause: error,
        );
      }
    });
  }

  Future<void> release(Object holder) {
    if (!_holders.remove(holder) || _holders.isNotEmpty) {
      return _operation;
    }
    return _enqueue(() async {
      try {
        await ReaderPlatform.instance.setKeepScreenOn(false);
      } catch (error) {
        throw ReaderFailure(
          ReaderFailureKind.platform,
          '无法释放屏幕常亮',
          cause: error,
        );
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final Future<void> next = _operation.then(
      (_) => action(),
      onError: (_) => action(),
    );
    _operation = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
