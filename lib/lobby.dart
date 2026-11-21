import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'client.dart';

class Lobby extends StatefulWidget {
  const Lobby({
    super.key,
    required this.state,
    required this.onConnect,
    required this.onCancel,
    this.initialAddress = '',
    this.account,
    this.requestingRemote = false,
    this.onSettings,
  });

  final ClientState state;
  final ValueChanged<String>? onConnect;
  final VoidCallback onCancel;
  final String initialAddress;
  final Widget? account;
  final bool requestingRemote;
  final VoidCallback? onSettings;

  @override
  State<Lobby> createState() => _LobbyState();
}

class _LobbyState extends State<Lobby> {
  final _form = GlobalKey<FormState>();
  late final _address = TextEditingController(text: widget.initialAddress);
  bool get _pending => widget.state.pending || widget.requestingRemote;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pending ||
        widget.onConnect == null ||
        !_form.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    widget.onConnect!(_address.text.trim());
  }

  static String? _validate(String? value) {
    final input = (value ?? '').trim();
    final bracketed = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(input);
    final ipv4 = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d+))?$')
        .firstMatch(input);
    final match = bracketed ?? ipv4;
    final host = match?[1] ?? input;
    final scoped = host.split('%');
    if (scoped.length > 2 ||
        (scoped.length == 2 &&
            (!scoped.first.contains(':') ||
                !RegExp(r'^[\w.-]+$').hasMatch(scoped.last))) ||
        InternetAddress.tryParse(scoped.first) == null) {
      return '请输入有效的 IPv4 或 IPv6 地址';
    }
    final port = int.tryParse(match?[2] ?? '38711');
    if (port == null || port < 1 || port > 65535) return '端口范围为 1–65535';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final state = widget.state;
    final status = widget.requestingRemote
        ? '正在获取主机连接信息…'
        : switch (state.phase) {
            Phase.approval => '请在主机上的 RinCast Streamer 中允许配对。',
            Phase.connecting => '正在连接主机…',
            Phase.failed => state.status,
            _ => null,
          };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: palette.primaryContainer,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.desktop_windows_outlined,
                          color: palette.onPrimaryContainer,
                          size: 28,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        if (widget.onSettings case final openSettings?)
                          IconButton(
                            tooltip: '串流设置',
                            onPressed: openSettings,
                            icon: const Icon(Icons.settings_outlined),
                          ),
                        IconButton(
                          tooltip: '关于 FogShot',
                          onPressed: () => showAboutDialog(
                            context: context,
                            applicationName: 'FogShot',
                            applicationVersion: '0.1.0',
                          ),
                          icon: const Icon(Icons.info_outline),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'FogShot',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '连接 RinCast Streamer，查看并控制远程桌面。',
                  style: theme.textTheme.bodyLarge,
                ),
                if (widget.account case final account?) ...[
                  const SizedBox(height: 24),
                  account,
                ],
                const SizedBox(height: 36),
                Text('主机地址', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                Form(
                  key: _form,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _address,
                          enabled: !_pending,
                          validator: _validate,
                          onFieldSubmitted: (_) => _submit(),
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.go,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            hintText: '192.168.1.42',
                            prefixIcon: Icon(Icons.lan_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 56,
                        child: FilledButton(
                          onPressed: _pending
                              ? widget.onCancel
                              : (widget.onConnect == null ? null : _submit),
                          child: Text(_pending ? '取消' : '连接'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      style: TextStyle(
                        color: state.phase == Phase.failed
                            ? palette.error
                            : palette.primary,
                      ),
                    ),
                  ),
                ],
                if (state.discover) ...[
                  const SizedBox(height: 30),
                  Text('附近的主机', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  if (state.hosts.isEmpty)
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      tileColor: palette.surfaceContainer,
                      leading: const Icon(Icons.wifi_find_outlined),
                      title: Text(
                        widget.onConnect == null ? '正在初始化客户端…' : '正在搜索局域网…',
                      ),
                      subtitle: const Text('也可以手动输入 Streamer 显示的地址。'),
                    )
                  else
                    for (final host in state.hosts) ...[
                      ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        tileColor: palette.surfaceContainer,
                        leading: const Icon(Icons.computer),
                        title: Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(host.address),
                        trailing: host.busy
                            ? const Text('忙碌')
                            : const Icon(Icons.chevron_right),
                        onTap: _pending || host.busy || widget.onConnect == null
                            ? null
                            : () {
                                FocusScope.of(context).unfocus();
                                widget.onConnect!(host.address);
                              },
                      ),
                      const SizedBox(height: 7),
                    ],
                ] else ...[
                  const SizedBox(height: 14),
                  const Text('请前往主机的 RinCast Streamer 首页查看地址。'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
