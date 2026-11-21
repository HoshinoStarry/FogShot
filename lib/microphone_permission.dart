import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('host.hoshino.fogshot/microphone');

Future<bool> requestMicrophonePermission() async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      try {
        return await _channel.invokeMethod<bool>('request') ?? false;
      } on MissingPluginException {
        return false;
      } on PlatformException {
        return false;
      }
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return true;
  }
}
