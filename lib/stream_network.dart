import 'package:material_ui/material_ui.dart';

class StreamNetwork {
  const StreamNetwork({
    this.route = '',
    this.codec = '',
    this.width = 0,
    this.height = 0,
    this.rttMs,
    this.jitterMs,
    this.fps,
    this.mbps,
    this.targetMbps,
    this.lossPercent,
    this.recovered = 0,
    this.captureEncodeMs,
    this.encodeMs,
    this.downlinkMs,
    this.decodeMs,
    this.captureToDecodeMs,
  });

  factory StreamNetwork.fromJson(Map<String, dynamic> data) => StreamNetwork(
    route: data['route'] as String? ?? '',
    codec: data['codec'] as String? ?? '',
    width: data['width'] as int? ?? 0,
    height: data['height'] as int? ?? 0,
    rttMs: (data['rttMs'] as num?)?.toDouble(),
    jitterMs: (data['jitterMs'] as num?)?.toDouble(),
    fps: (data['fps'] as num?)?.toDouble(),
    mbps: (data['mbps'] as num?)?.toDouble(),
    targetMbps: (data['targetMbps'] as num?)?.toDouble(),
    lossPercent: (data['lossPercent'] as num?)?.toDouble(),
    recovered: data['recovered'] as int? ?? 0,
    captureEncodeMs: (data['captureEncodeMs'] as num?)?.toDouble(),
    encodeMs: (data['encodeMs'] as num?)?.toDouble(),
    downlinkMs: (data['downlinkMs'] as num?)?.toDouble(),
    decodeMs: (data['decodeMs'] as num?)?.toDouble(),
    captureToDecodeMs: (data['captureToDecodeMs'] as num?)?.toDouble(),
  );

  final String route, codec;
  final int width, height, recovered;
  final double? rttMs, jitterMs, fps, mbps, targetMbps, lossPercent;
  final double? captureEncodeMs,
      encodeMs,
      downlinkMs,
      decodeMs,
      captureToDecodeMs;

  String get routeLabel => switch (route) {
    'lan4' => '局域网 IPv4',
    'lan6' => '局域网 IPv6',
    'vpn4' => 'VPN IPv4',
    'wan4' => '公网直连 IPv4',
    'wan6' => '公网直连 IPv6',
    _ => '直连',
  };

  String get compactLabel =>
      rttMs == null ? routeLabel : '${rttMs!.round()} ms';
}

class StreamNetworkPanel extends StatelessWidget {
  const StreamNetworkPanel({
    super.key,
    required this.metrics,
    required this.onClose,
  });

  final StreamNetwork metrics;
  final VoidCallback onClose;

  String _format(double? value, String unit, [int decimals = 1]) =>
      value == null ? '—' : '${value.toStringAsFixed(decimals)}$unit';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme;
    final resolution = metrics.width > 0 && metrics.height > 0
        ? '${metrics.width} × ${metrics.height}'
        : '—';
    final values = [
      ('往返时延', _format(metrics.rttMs, ' ms')),
      ('RTT 波动', _format(metrics.jitterMs, ' ms')),
      ('接收码率', _format(metrics.mbps, ' Mbps')),
      ('目标码率', _format(metrics.targetMbps, ' Mbps')),
      ('解码帧率', _format(metrics.fps, ' fps', 0)),
      ('分辨率', resolution),
      ('纠错后丢片率', _format(metrics.lossPercent, '%')),
      ('FEC 恢复分片', '${metrics.recovered}'),
      ('捕获至编码完成', _format(metrics.captureEncodeMs, ' ms')),
      ('编码', _format(metrics.encodeMs, ' ms')),
      ('下行传输', _format(metrics.downlinkMs, ' ms')),
      ('解码', _format(metrics.decodeMs, ' ms')),
      ('捕获至解码完成', _format(metrics.captureToDecodeMs, ' ms')),
      ('编码格式', metrics.codec.isEmpty ? '—' : metrics.codec),
    ];
    return Material(
      color: color.surfaceContainerHigh,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 4, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('网络状态', style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: '关闭网络状态',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            Text(
              metrics.routeLabel,
              style: theme.textTheme.bodySmall?.copyWith(color: color.primary),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < values.length; i += 2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    for (final (label, value) in values.skip(i).take(2))
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: color.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              value,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
