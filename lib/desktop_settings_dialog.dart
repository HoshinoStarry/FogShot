import 'package:material_ui/material_ui.dart';

import 'desktop_settings.dart';

/// Edits settings locally and returns null when the user cancels.
Future<DesktopSettings?> showDesktopSettings(
  BuildContext context,
  DesktopSettings settings, {
  Set<VideoCodecPreference> supportedCodecs = const {VideoCodecPreference.h264},
}) => showDialog<DesktopSettings>(
  context: context,
  builder: (_) => _DesktopSettingsDialog(
    initial: settings,
    supportedCodecs: supportedCodecs,
  ),
);

class _DesktopSettingsDialog extends StatefulWidget {
  const _DesktopSettingsDialog({
    required this.initial,
    required this.supportedCodecs,
  });

  final DesktopSettings initial;
  final Set<VideoCodecPreference> supportedCodecs;

  @override
  State<_DesktopSettingsDialog> createState() => _DesktopSettingsDialogState();
}

class _DesktopSettingsDialogState extends State<_DesktopSettingsDialog> {
  late DesktopFrameRate _frameRate = widget.initial.frameRate;
  late bool _hostBitrate = widget.initial.desktopBitrateMbps == 0;
  late int _bitrate = widget.initial.desktopBitrateMbps == 0
      ? 40
      : widget.initial.desktopBitrateMbps;
  late bool _adaptiveBitrate = widget.initial.adaptiveBitrate;
  late bool _audioPassthrough = widget.initial.audioPassthrough;
  late double _playbackVolume = widget.initial.playbackVolume;
  late double _brightness = widget.initial.brightness;
  late DesktopDecodePreset _decodePreset = widget.initial.decodePreset;
  late VideoCodecPreference _codec =
      widget.initial.preferredCodec == VideoCodecPreference.auto ||
          widget.supportedCodecs.contains(widget.initial.preferredCodec)
      ? widget.initial.preferredCodec
      : VideoCodecPreference.auto;
  late bool _tenBit = widget.initial.tenBit;
  late bool _autoReconnect = widget.initial.autoReconnect;
  late bool _autoConnect = widget.initial.autoConnect;

  bool get _tenBitAvailable =>
      widget.supportedCodecs.contains(VideoCodecPreference.av1) &&
      (_codec == VideoCodecPreference.auto ||
          _codec == VideoCodecPreference.av1);

  DesktopSettings get _edited => DesktopSettings(
    frameRate: _frameRate,
    desktopBitrateMbps: _hostBitrate ? 0 : _bitrate,
    adaptiveBitrate: _adaptiveBitrate,
    audioPassthrough: _audioPassthrough,
    playbackVolume: _playbackVolume,
    brightness: _brightness,
    maxDecodeWidth: _decodePreset.maxWidth,
    maxDecodeHeight: _decodePreset.maxHeight,
    preferredCodec: _codec,
    tenBit: _tenBit,
    autoReconnect: _autoReconnect,
    autoConnect: _autoConnect,
    lastAddress: widget.initial.lastAddress,
    lastPcId: widget.initial.lastPcId,
    lastPcAccountId: widget.initial.lastPcAccountId,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: (screen.height - 40).clamp(360, 760),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.tune, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '桌面串流设置',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _section('画面'),
                    _choiceRow<DesktopFrameRate>(
                      label: '帧率',
                      value: _frameRate,
                      options: const {
                        DesktopFrameRate.auto: '自动',
                        DesktopFrameRate.fps30: '30 fps',
                        DesktopFrameRate.fps60: '60 fps',
                        DesktopFrameRate.fps90: '90 fps',
                      },
                      onChanged: (value) => setState(() => _frameRate = value),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('使用主机的默认码率'),
                      subtitle: const Text('关闭后可覆盖桌面串流码率'),
                      value: _hostBitrate,
                      onChanged: (value) =>
                          setState(() => _hostBitrate = value),
                    ),
                    if (!_hostBitrate) ...[
                      Row(
                        children: [
                          const Text('桌面码率'),
                          const Spacer(),
                          Text('$_bitrate Mbps'),
                        ],
                      ),
                      Slider(
                        value: _bitrate.toDouble(),
                        min: DesktopSettings.minDesktopBitrateMbps.toDouble(),
                        max: DesktopSettings.maxDesktopBitrateMbps.toDouble(),
                        divisions:
                            (DesktopSettings.maxDesktopBitrateMbps -
                                DesktopSettings.minDesktopBitrateMbps) ~/
                            DesktopSettings.desktopBitrateStepMbps,
                        label: '$_bitrate Mbps',
                        onChanged: (value) => setState(
                          () => _bitrate =
                              (value / DesktopSettings.desktopBitrateStepMbps)
                                  .round() *
                              DesktopSettings.desktopBitrateStepMbps,
                        ),
                      ),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('自适应码率'),
                      subtitle: const Text('根据网络状况自动调整清晰度'),
                      value: _adaptiveBitrate,
                      onChanged: (value) =>
                          setState(() => _adaptiveBitrate = value),
                    ),
                    _choiceRow<DesktopDecodePreset>(
                      label: '最大解码尺寸',
                      value: _decodePreset,
                      options: const {
                        DesktopDecodePreset.native: '自动',
                        DesktopDecodePreset.p2160: '2160p',
                        DesktopDecodePreset.p1440: '1440p',
                        DesktopDecodePreset.p1080: '1080p',
                        DesktopDecodePreset.p720: '720p',
                      },
                      onChanged: (value) =>
                          setState(() => _decodePreset = value),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '最大解码尺寸将在下次连接时生效。',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _choiceRow<VideoCodecPreference>(
                      label: '首选视频编码',
                      value: _codec,
                      options: {
                        VideoCodecPreference.auto: '自动',
                        for (final codec in widget.supportedCodecs)
                          if (codec != VideoCodecPreference.auto)
                            codec: switch (codec) {
                              VideoCodecPreference.h264 => 'H.264',
                              VideoCodecPreference.hevc => 'HEVC',
                              VideoCodecPreference.av1 => 'AV1',
                              VideoCodecPreference.auto => '自动',
                            },
                      },
                      onChanged: (value) => setState(() => _codec = value),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '选择的主机或设备不支持时，会自动改用可用编码。',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    if (_tenBitAvailable)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('10 位色深'),
                        subtitle: const Text('需要主机支持 AV1 10 位编码'),
                        value: _tenBit,
                        onChanged: (value) => setState(() => _tenBit = value),
                      ),
                    const SizedBox(height: 22),
                    _section('声音与亮度'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('播放远端音频'),
                      subtitle: const Text('接收并通过本机扬声器播放主机声音'),
                      value: _audioPassthrough,
                      onChanged: (value) =>
                          setState(() => _audioPassthrough = value),
                    ),
                    Row(
                      children: [
                        const Text('播放音量'),
                        const Spacer(),
                        Text('${(_playbackVolume * 100).round()}%'),
                      ],
                    ),
                    Slider(
                      value: _playbackVolume,
                      min: DesktopSettings.minPlaybackVolume,
                      max: DesktopSettings.maxPlaybackVolume,
                      divisions: 20,
                      label: '${(_playbackVolume * 100).round()}%',
                      onChanged: _audioPassthrough
                          ? (value) => setState(() => _playbackVolume = value)
                          : null,
                    ),
                    Row(
                      children: [
                        const Text('画面亮度'),
                        const Spacer(),
                        Text('${(_brightness * 100).round()}%'),
                      ],
                    ),
                    Slider(
                      value: _brightness,
                      min: DesktopSettings.minBrightness,
                      max: DesktopSettings.maxBrightness,
                      divisions: 26,
                      label: '${(_brightness * 100).round()}%',
                      onChanged: (value) => setState(() => _brightness = value),
                    ),
                    const SizedBox(height: 14),
                    _section('连接'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('自动重连'),
                      subtitle: const Text('连接意外中断后尝试恢复上次会话'),
                      value: _autoReconnect,
                      onChanged: (value) =>
                          setState(() => _autoReconnect = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启动时自动连接'),
                      subtitle: const Text('连接到上次使用且在线的主机'),
                      value: _autoConnect,
                      onChanged: (value) =>
                          setState(() => _autoConnect = value),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_edited),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _choiceRow<T>({
    required String label,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in options.entries)
            ChoiceChip(
              label: Text(option.value),
              selected: option.key == value,
              onSelected: (_) => onChanged(option.key),
            ),
        ],
      ),
    ],
  );
}
