import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum DesktopFrameRate {
  auto(0),
  fps30(30),
  fps60(60),
  fps90(90);

  const DesktopFrameRate(this.value);
  final int value;

  static DesktopFrameRate fromValue(int value) => switch (value) {
    0 => auto,
    30 => fps30,
    60 => fps60,
    90 => fps90,
    _ => auto,
  };
}

enum VideoCodecPreference {
  auto('auto'),
  h264('h264'),
  hevc('hevc'),
  av1('av1');

  const VideoCodecPreference(this.value);
  final String value;

  static VideoCodecPreference fromValue(String? value) => switch (value) {
    'h264' => h264,
    'hevc' => hevc,
    'av1' => av1,
    _ => auto,
  };
}

enum DesktopDecodePreset {
  native(0, 0),
  p2160(3840, 2160),
  p1440(2560, 1440),
  p1080(1920, 1080),
  p720(1280, 720);

  const DesktopDecodePreset(this.maxWidth, this.maxHeight);
  final int maxWidth;
  final int maxHeight;

  static DesktopDecodePreset fromDimensions(int width, int height) {
    for (final preset in values) {
      if (preset.maxWidth == width && preset.maxHeight == height) {
        return preset;
      }
    }
    return native;
  }
}

class DesktopSettings {
  const DesktopSettings({
    this.frameRate = DesktopFrameRate.fps60,
    this.desktopBitrateMbps = 0,
    this.adaptiveBitrate = true,
    this.audioPassthrough = true,
    this.playbackVolume = 1,
    this.brightness = 1,
    this.maxDecodeWidth = 0,
    this.maxDecodeHeight = 0,
    this.preferredCodec = VideoCodecPreference.h264,
    this.tenBit = false,
    this.autoReconnect = true,
    this.autoConnect = false,
    this.lastAddress = '',
    this.lastPcId = '',
    this.lastPcAccountId = '',
  });

  static const fileName = 'desktop_settings.json';
  static const minDesktopBitrateMbps = 10;
  static const maxDesktopBitrateMbps = 150;
  static const desktopBitrateStepMbps = 5;
  static const minPlaybackVolume = 0.0;
  static const maxPlaybackVolume = 1.0;
  static const minBrightness = 0.3;
  static const maxBrightness = 1.6;

  final DesktopFrameRate frameRate;
  final int desktopBitrateMbps;
  final bool adaptiveBitrate;
  final bool audioPassthrough;
  final double playbackVolume;
  final double brightness;
  final int maxDecodeWidth;
  final int maxDecodeHeight;
  final VideoCodecPreference preferredCodec;
  final bool tenBit;
  final bool autoReconnect;
  final bool autoConnect;
  final String lastAddress;
  final String lastPcId;
  final String lastPcAccountId;

  DesktopDecodePreset get decodePreset =>
      DesktopDecodePreset.fromDimensions(maxDecodeWidth, maxDecodeHeight);

  /// Mobile defaults to 30 fps. Other platforms default to a safe 60 fps.
  factory DesktopSettings.defaults({bool? mobile}) {
    final isMobile = mobile ?? Platform.isAndroid || Platform.isIOS;
    return DesktopSettings(
      frameRate: isMobile ? DesktopFrameRate.fps30 : DesktopFrameRate.fps60,
    );
  }

  /// Parses persisted JSON, falling back per field when a value is invalid.
  factory DesktopSettings.parse(String? source, {bool? mobile}) {
    final defaults = DesktopSettings.defaults(mobile: mobile);
    if (source == null || source.trim().isEmpty) return defaults;

    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return defaults;
    }
    if (decoded is! Map<String, dynamic>) return defaults;

    final frameRateValue = _readInt(decoded['desktopFps']);
    final frameRate = switch (frameRateValue) {
      0 => DesktopFrameRate.auto,
      30 => DesktopFrameRate.fps30,
      60 => DesktopFrameRate.fps60,
      90 => DesktopFrameRate.fps90,
      _ => defaults.frameRate,
    };

    final bitrateValue = _readInt(decoded['desktopBitrateMbps']);
    final bitrate = bitrateValue == null
        ? defaults.desktopBitrateMbps
        : bitrateValue == 0
        ? 0
        : _clampRound(
            bitrateValue,
            minDesktopBitrateMbps,
            maxDesktopBitrateMbps,
          );

    final dimensions = _readDecodeDimensions(decoded);
    return DesktopSettings(
      frameRate: frameRate,
      desktopBitrateMbps: bitrate,
      adaptiveBitrate: _readBool(
        decoded['adaptiveBitrate'],
        defaults.adaptiveBitrate,
      ),
      audioPassthrough: _readBool(
        decoded['streamAudio'],
        defaults.audioPassthrough,
      ),
      playbackVolume: _readDouble(
        decoded['volume'],
        defaults.playbackVolume,
        minPlaybackVolume,
        maxPlaybackVolume,
      ),
      brightness: _readDouble(
        decoded['skyBrightness'],
        defaults.brightness,
        minBrightness,
        maxBrightness,
      ),
      maxDecodeWidth: dimensions.$1,
      maxDecodeHeight: dimensions.$2,
      preferredCodec: decoded['codec'] == null
          ? defaults.preferredCodec
          : VideoCodecPreference.fromValue(_readString(decoded['codec'])),
      tenBit: _readBool(decoded['tenBit'], defaults.tenBit),
      autoReconnect: _readBool(
        decoded['autoReconnect'],
        defaults.autoReconnect,
      ),
      autoConnect: _readBool(decoded['autoConnect'], defaults.autoConnect),
      lastAddress: _readString(decoded['lastAddress']) ?? defaults.lastAddress,
      lastPcId: _readString(decoded['lastPcId']) ?? defaults.lastPcId,
      lastPcAccountId:
          _readString(decoded['lastPcAccountId']) ?? defaults.lastPcAccountId,
    );
  }

  static Future<DesktopSettings> load({String? path, bool? mobile}) async {
    final defaults = DesktopSettings.defaults(mobile: mobile);
    try {
      final settingsPath = path ?? await _defaultPath();
      final file = File(settingsPath);
      if (!await file.exists()) return defaults;
      return DesktopSettings.parse(await file.readAsString(), mobile: mobile);
    } on FileSystemException {
      return defaults;
    }
  }

  Future<void> save({String? path}) async {
    final settingsPath = path ?? await _defaultPath();
    final target = File(settingsPath);
    await target.parent.create(recursive: true);
    final temporary = File('$settingsPath.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    try {
      await temporary.rename(settingsPath);
    } on FileSystemException {
      await target.writeAsString(
        const JsonEncoder.withIndent('  ').convert(toJson()),
        flush: true,
      );
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Map<String, dynamic> toJson() => {
    'desktopFps': frameRate.value,
    'desktopBitrateMbps': desktopBitrateMbps,
    'adaptiveBitrate': adaptiveBitrate,
    'streamAudio': audioPassthrough,
    'volume': playbackVolume,
    'skyBrightness': brightness,
    'maxDecodeWidth': maxDecodeWidth,
    'maxDecodeHeight': maxDecodeHeight,
    'codec': preferredCodec.value,
    'tenBit': tenBit,
    'autoReconnect': autoReconnect,
    'autoConnect': autoConnect,
    'lastAddress': lastAddress,
    'lastPcId': lastPcId,
    'lastPcAccountId': lastPcAccountId,
  };

  DesktopSettings copyWith({
    DesktopFrameRate? frameRate,
    int? desktopBitrateMbps,
    bool? adaptiveBitrate,
    bool? audioPassthrough,
    double? playbackVolume,
    double? brightness,
    int? maxDecodeWidth,
    int? maxDecodeHeight,
    VideoCodecPreference? preferredCodec,
    bool? tenBit,
    bool? autoReconnect,
    bool? autoConnect,
    String? lastAddress,
    String? lastPcId,
    String? lastPcAccountId,
  }) => DesktopSettings(
    frameRate: frameRate ?? this.frameRate,
    desktopBitrateMbps: desktopBitrateMbps ?? this.desktopBitrateMbps,
    adaptiveBitrate: adaptiveBitrate ?? this.adaptiveBitrate,
    audioPassthrough: audioPassthrough ?? this.audioPassthrough,
    playbackVolume: playbackVolume ?? this.playbackVolume,
    brightness: brightness ?? this.brightness,
    maxDecodeWidth: maxDecodeWidth ?? this.maxDecodeWidth,
    maxDecodeHeight: maxDecodeHeight ?? this.maxDecodeHeight,
    preferredCodec: preferredCodec ?? this.preferredCodec,
    tenBit: tenBit ?? this.tenBit,
    autoReconnect: autoReconnect ?? this.autoReconnect,
    autoConnect: autoConnect ?? this.autoConnect,
    lastAddress: lastAddress ?? this.lastAddress,
    lastPcId: lastPcId ?? this.lastPcId,
    lastPcAccountId: lastPcAccountId ?? this.lastPcAccountId,
  );

  static Future<String> _defaultPath() async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}${Platform.pathSeparator}$fileName';
  }

  static int? _readInt(Object? value) => value is num ? value.round() : null;

  static String? _readString(Object? value) => value is String ? value : null;

  static double _readDouble(
    Object? value,
    double fallback,
    double minimum,
    double maximum,
  ) {
    if (value is! num || !value.isFinite) return fallback;
    return value.toDouble().clamp(minimum, maximum);
  }

  static bool _readBool(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static int _clampRound(int value, int minimum, int maximum) =>
      value.clamp(minimum, maximum);

  static (int, int) _readDecodeDimensions(Map<String, dynamic> json) {
    final width = _readInt(json['maxDecodeWidth']);
    final height = _readInt(json['maxDecodeHeight']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return (0, 0);
    }
    for (final preset in DesktopDecodePreset.values) {
      if (preset.maxWidth == width && preset.maxHeight == height) {
        return (width, height);
      }
    }
    return (0, 0);
  }
}
