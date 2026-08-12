import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

abstract class ReaderPlatform extends PlatformInterface {
  ReaderPlatform() : super(token: _token);

  static final Object _token = Object();
  static ReaderPlatform _instance = MethodChannelReaderPlatform();

  static ReaderPlatform get instance => _instance;

  static set instance(ReaderPlatform value) {
    PlatformInterface.verifyToken(value, _token);
    _instance = value;
  }

  Future<void> setKeepScreenOn(bool enabled) {
    throw UnimplementedError('setKeepScreenOn() has not been implemented.');
  }

  bool get supportsKeepScreenOn => false;
}

class MethodChannelReaderPlatform extends ReaderPlatform {
  static const MethodChannel _channel = MethodChannel('novel_reader_ui/system');

  @override
  bool get supportsKeepScreenOn =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Future<void> setKeepScreenOn(bool enabled) {
    return _channel.invokeMethod<void>('setKeepScreenOn', enabled);
  }
}
