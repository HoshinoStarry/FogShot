import 'dart:io';

import 'package:flutter/services.dart';

const _deviceNameChannel = MethodChannel('host.hoshino.fogshot/device_name');
const _currentDeviceNameMethod = 'currentDeviceName';

/// Returns the current user-visible device name without requesting permission.
Future<String> currentDeviceName() async {
  if (Platform.isWindows || Platform.isLinux) {
    return Platform.localHostname;
  }

  try {
    final name = await _deviceNameChannel.invokeMethod<String>(
      _currentDeviceNameMethod,
    );
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? Platform.localHostname : trimmed;
  } on MissingPluginException {
    return Platform.localHostname;
  } on PlatformException {
    return Platform.localHostname;
  }
}
