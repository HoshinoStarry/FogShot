import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'ip_location.dart';

class StreamNetwork {
  const StreamNetwork({
    this.route = '',
    this.endpoint = '',
    this.localIp = '',
    this.observedLocalIp = '',
    this.rttMs,
    this.jitterMs,
    this.mbps,
    this.uploadMbps,
    this.targetMbps,
    this.lossPercent,
    this.activeSeconds,
    this.lastPacketMs,
    this.bytesReceived,
    this.bytesSent,
    this.packetsReceived,
    this.packetsSent,
    this.packetsRejected,
    this.controlRetransmits,
    this.fragmentsReceived,
    this.fragmentsLost,
    this.recovered,
    this.audioPackets,
    this.clockSynchronized,
    this.streams = const [],
  });

  factory StreamNetwork.fromJson(Map<String, dynamic> data) => StreamNetwork(
    route: data['route'] as String? ?? '',
    endpoint: data['endpoint'] as String? ?? '',
    localIp: data['localIp'] as String? ?? '',
    observedLocalIp: data['observedLocalIp'] as String? ?? '',
    rttMs: (data['rttMs'] as num?)?.toDouble(),
    jitterMs: (data['jitterMs'] as num?)?.toDouble(),
    mbps: (data['mbps'] as num?)?.toDouble(),
    uploadMbps: (data['uploadMbps'] as num?)?.toDouble(),
    targetMbps: (data['targetMbps'] as num?)?.toDouble(),
    lossPercent: (data['lossPercent'] as num?)?.toDouble(),
    activeSeconds: data['activeSeconds'] as int?,
    lastPacketMs: data['lastPacketMs'] as int?,
    bytesReceived: data['bytesReceived'] as int?,
    bytesSent: data['bytesSent'] as int?,
    packetsReceived: data['packetsReceived'] as int?,
    packetsSent: data['packetsSent'] as int?,
    packetsRejected: data['packetsRejected'] as int?,
    controlRetransmits: data['controlRetransmits'] as int?,
    fragmentsReceived: data['fragmentsReceived'] as int?,
    fragmentsLost: data['fragmentsLost'] as int?,
    recovered: data['recovered'] as int?,
    audioPackets: data['audioPackets'] as int?,
    clockSynchronized: data['clockSynchronized'] as bool?,
    streams: [
      for (final item in data['streams'] as List? ?? const [])
        StreamVideoMetrics(item as Map<String, dynamic>),
    ],
  );

  final String route, endpoint, localIp, observedLocalIp;
  final double? rttMs, jitterMs, mbps, uploadMbps, targetMbps, lossPercent;
  final int? activeSeconds, lastPacketMs, bytesReceived, bytesSent;
  final int? packetsReceived, packetsSent, packetsRejected, controlRetransmits;
  final int? fragmentsReceived, fragmentsLost, recovered, audioPackets;
  final bool? clockSynchronized;
  final List<StreamVideoMetrics> streams;

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

class StreamVideoMetrics {
  StreamVideoMetrics(Map<String, dynamic> data)
    : name = data['name'] as String,
      active = data['active'] as bool,
      codec = data['codec'] as String,
      width = data['width'] as int,
      height = data['height'] as int,
      hostFps = (data['hostFps'] as num?)?.toDouble(),
      receiveFps = (data['receiveFps'] as num?)?.toDouble(),
      fps = (data['fps'] as num?)?.toDouble(),
      hostMbps = (data['hostMbps'] as num?)?.toDouble(),
      receiveMbps = (data['receiveMbps'] as num?)?.toDouble(),
      targetMbps = (data['targetMbps'] as num?)?.toDouble(),
      framesReceived = data['framesReceived'] as int?,
      framesLost = data['framesLost'] as int?,
      assemblyMs = (data['assemblyMs'] as num?)?.toDouble(),
      captureEncodeMs = (data['captureEncodeMs'] as num?)?.toDouble(),
      encodeMs = (data['encodeMs'] as num?)?.toDouble(),
      downlinkMs = (data['downlinkMs'] as num?)?.toDouble(),
      decodeMs = (data['decodeMs'] as num?)?.toDouble(),
      captureToDecodeMs = (data['captureToDecodeMs'] as num?)?.toDouble();

  final String name, codec;
  final bool active;
  final int width, height;
  final int? framesReceived, framesLost;
  final double? hostFps, receiveFps, fps, hostMbps, receiveMbps, targetMbps;
  final double? assemblyMs, captureEncodeMs, encodeMs, downlinkMs, decodeMs;
  final double? captureToDecodeMs;
}

class StreamNetworkPanel extends StatefulWidget {
  const StreamNetworkPanel({
    super.key,
    required this.metrics,
    required this.onClose,
    this.ipLocationService,
  });

  final StreamNetwork metrics;
  final VoidCallback onClose;
  final IpLocationService? ipLocationService;

  @override
  State<StreamNetworkPanel> createState() => _StreamNetworkPanelState();
}

class _StreamNetworkPanelState extends State<StreamNetworkPanel> {
  static final _ipLocation = IpLocationService();
  StreamNetwork get metrics => widget.metrics;
  String? _peerIp, _localIp;
  Future<IpLocation?>? _peerLocation, _localLocation;
  bool _localFromRendezvous = false;
  InternetAddressType? _localHttpsFamily;

  @override
  void initState() {
    super.initState();
    _lookUpEndpoints();
  }

  @override
  void didUpdateWidget(StreamNetworkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.metrics;
    if (metrics.endpoint != previous.endpoint ||
        metrics.route != previous.route ||
        metrics.localIp != previous.localIp ||
        metrics.observedLocalIp != previous.observedLocalIp) {
      _lookUpEndpoints();
    }
  }

  void _lookUpEndpoints() {
    final service = widget.ipLocationService ?? _ipLocation;
    final peerIp = endpointIp(metrics.endpoint);
    final peer = peerIp == null ? null : publicIp(peerIp);
    if (_peerIp != peerIp) {
      _peerIp = peerIp;
      _peerLocation = peer == null ? null : service.lookup(peer.address);
    }

    final observed = metrics.route.startsWith('wan')
        ? publicIp(metrics.observedLocalIp)
        : null;
    final localIp = observed?.address ?? metrics.localIp;
    final localPublic = publicIp(localIp);
    final httpsFamily = localPublic == null ? peer?.type : null;
    if (_localIp != localIp || _localHttpsFamily != httpsFamily) {
      _localLocation = localPublic != null
          ? service.lookup(localPublic.address)
          : (httpsFamily == null ? null : service.lookupSelf(httpsFamily));
    }
    _localIp = localIp;
    _localFromRendezvous = observed != null;
    _localHttpsFamily = httpsFamily;
  }

  Widget _address(
    BuildContext context,
    String title,
    String? ip,
    Future<IpLocation?>? lookup, {
    bool showReturnedIp = true,
  }) {
    final theme = Theme.of(context);
    return FutureBuilder<IpLocation?>(
      key: ValueKey((title, ip, lookup)),
      future: lookup,
      builder: (context, result) {
        final location = result.data;
        final operator = [
          ?location?.isp,
          if (location?.asn case final asn?) 'AS$asn',
        ].join(' · ');
        final address = (showReturnedIp ? location?.ip.address : null) ?? ip;
        final area = lookup == null
            ? (address == null || address.isEmpty ? '—' : '内网或保留地址')
            : (result.connectionState == ConnectionState.waiting
                  ? '查询中…'
                  : location?.label ?? '归属地不可用');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.labelMedium),
              Text(
                address == null || address.isEmpty ? '—' : address,
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                operator.isEmpty ? area : '$area · $operator',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _format(double? value, String unit, [int decimals = 1]) =>
      value == null ? '—' : '${value.toStringAsFixed(decimals)}$unit';

  String _count(int? value, [String unit = '']) =>
      value == null ? '—' : '$value$unit';

  String _traffic(int? bytes) {
    if (bytes == null) return '—';
    if (bytes >= 1 << 30) return _format(bytes / (1 << 30), ' GiB');
    if (bytes >= 1 << 20) return _format(bytes / (1 << 20), ' MiB');
    if (bytes >= 1 << 10) return _format(bytes / (1 << 10), ' KiB');
    return '$bytes B';
  }

  String _duration(int? seconds) {
    if (seconds == null) return '—';
    return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme;

    Widget group(String label, List<(String, String)> values) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(color: color.primary),
          ),
          const SizedBox(height: 5),
          for (var i = 0; i < values.length; i += 2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (name, value) in values.skip(i).take(2))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
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
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    return Material(
      color: color.surfaceContainerHigh,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('网络状态', style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: '关闭网络状态',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  group('连接', [
                    ('当前路径', metrics.routeLabel),
                    ('已连接', _duration(metrics.activeSeconds)),
                    ('往返时延', _format(metrics.rttMs, ' ms')),
                    ('RTT 波动', _format(metrics.jitterMs, ' ms')),
                    ('最近收包', _count(metrics.lastPacketMs, ' ms 前')),
                    (
                      '时钟同步',
                      switch (metrics.clockSynchronized) {
                        true => '已同步',
                        false => '同步中',
                        null => '—',
                      },
                    ),
                  ]),
                  if (metrics.endpoint.isNotEmpty) ...[
                    const Divider(height: 12),
                    Text(
                      'P2P 双端 · ip.sb',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: color.primary,
                      ),
                    ),
                    _address(
                      context,
                      _localFromRendezvous
                          ? '本机 · UDP 引介观测'
                          : (_localHttpsFamily != null
                                ? '本机 · HTTPS 出口'
                                : '本机'),
                      _localHttpsFamily != null ? null : _localIp,
                      _localLocation,
                    ),
                    _address(
                      context,
                      '主机',
                      metrics.endpoint,
                      _peerLocation,
                      showReturnedIp: false,
                    ),
                  ],
                  const Divider(height: 12),
                  group('数据收发', [
                    ('接收码率', _format(metrics.mbps, ' Mbps')),
                    ('发送码率', _format(metrics.uploadMbps, ' Mbps', 2)),
                    ('视频目标码率', _format(metrics.targetMbps, ' Mbps')),
                    ('音频解码包', _count(metrics.audioPackets)),
                    ('累计接收', _traffic(metrics.bytesReceived)),
                    ('累计发送', _traffic(metrics.bytesSent)),
                    ('接收数据报', _count(metrics.packetsReceived)),
                    ('发送数据报', _count(metrics.packetsSent)),
                  ]),
                  const Divider(height: 12),
                  group('丢包与纠错', [
                    ('纠错后丢片率', _format(metrics.lossPercent, '%', 2)),
                    ('FEC 恢复分片', _count(metrics.recovered)),
                    ('收到的视频分片', _count(metrics.fragmentsReceived)),
                    ('未恢复分片', _count(metrics.fragmentsLost)),
                    ('可靠控制重传', _count(metrics.controlRetransmits)),
                    ('丢弃的数据报', _count(metrics.packetsRejected)),
                  ]),
                  for (final stream in metrics.streams) ...[
                    const Divider(height: 12),
                    group(
                      stream.active ? '${stream.name} · 当前显示器' : stream.name,
                      [
                        ('分辨率', '${stream.width} × ${stream.height}'),
                        ('编码格式', stream.codec),
                        ('主机帧率', _format(stream.hostFps, ' fps')),
                        ('接收帧率', _format(stream.receiveFps, ' fps')),
                        ('解码帧率', _format(stream.fps, ' fps')),
                        ('视频目标码率', _format(stream.targetMbps, ' Mbps')),
                        ('主机视频码率', _format(stream.hostMbps, ' Mbps')),
                        ('接收视频码率', _format(stream.receiveMbps, ' Mbps')),
                        ('已组装视频帧', _count(stream.framesReceived)),
                        ('丢失视频帧', _count(stream.framesLost)),
                        ('捕获至编码完成', _format(stream.captureEncodeMs, ' ms')),
                        ('主机编码', _format(stream.encodeMs, ' ms')),
                        ('下行传输', _format(stream.downlinkMs, ' ms')),
                        ('分片到达间隔', _format(stream.assemblyMs, ' ms')),
                        ('解码', _format(stream.decodeMs, ' ms')),
                        ('捕获至解码完成', _format(stream.captureToDecodeMs, ' ms')),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
