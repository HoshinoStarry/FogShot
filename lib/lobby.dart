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
  DialogRoute<void>? _accountRoute;
  NavigatorState? _accountNavigator;

  bool get _pending => widget.state.pending || widget.requestingRemote;

  @override
  void didUpdateWidget(covariant Lobby oldWidget) {
    super.didUpdateWidget(oldWidget);
    final route = _accountRoute;
    final navigator = _accountNavigator;
    if (route != null &&
        navigator != null &&
        widget.requestingRemote &&
        !oldWidget.requestingRemote) {
      _accountRoute = null;
      _accountNavigator = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) navigator.removeRoute(route);
      });
    }
  }

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

  Future<void> _showAccount() async {
    if (widget.account == null || _accountRoute != null) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        final compact = size.width < 480;
        return Dialog(
          insetPadding: EdgeInsets.all(compact ? 12 : 28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 540,
              maxHeight: size.height * 0.84,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 20,
                14,
                compact ? 16 : 20,
                20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'RinCast 账户',
                          style: Theme.of(dialogContext).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭账户',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  widget.account!,
                ],
              ),
            ),
          ),
        );
      },
    );
    _accountRoute = route;
    _accountNavigator = navigator;
    await navigator.push(route);
    if (identical(_accountRoute, route)) {
      _accountRoute = null;
      _accountNavigator = null;
    }
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

  Widget _header(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: compact ? 40 : 44,
          height: compact ? 40 : 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: palette.primaryContainer,
            border: Border.all(color: palette.primary.withAlpha(70)),
          ),
          child: Icon(
            Icons.cast_connected_rounded,
            color: palette.onPrimaryContainer,
            size: compact ? 23 : 25,
          ),
        ),
        SizedBox(width: compact ? 10 : 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'FogShot',
                style:
                    (compact
                            ? theme.textTheme.titleLarge
                            : theme.textTheme.headlineSmall)
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
              ),
            ],
          ),
        ),
        if (widget.account != null)
          _HeaderAction(
            tooltip: 'RinCast 账户',
            onPressed: _showAccount,
            icon: Icons.account_circle_outlined,
          ),
        if (widget.onSettings case final openSettings?)
          _HeaderAction(
            tooltip: '串流设置',
            onPressed: openSettings,
            icon: Icons.tune_rounded,
          ),
        _HeaderAction(
          tooltip: '关于 FogShot',
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: 'FogShot',
            applicationVersion: '0.1.0',
          ),
          icon: Icons.info_outline_rounded,
        ),
      ],
    );
  }

  Widget _connectCard(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final state = widget.state;
    final failed = !widget.requestingRemote && state.phase == Phase.failed;
    final status = widget.requestingRemote
        ? '正在获取账号主机'
        : switch (state.phase) {
            Phase.approval => '等待主机允许配对',
            Phase.connecting => '正在连接主机',
            Phase.failed => state.status,
            _ => null,
          };
    final statusColor = failed
        ? palette.errorContainer
        : palette.primaryContainer.withAlpha(150);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: palette.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: palette.outlineVariant.withAlpha(110)),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 18 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: palette.primary.withAlpha(24),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.near_me_outlined,
                    color: palette.primary,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Text('直接连接', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_pending)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: failed ? palette.error : palette.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
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
                        hintText: 'IP 地址或 [IPv6]:端口',
                        prefixIcon: Icon(Icons.lan_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: compact ? 82 : 96,
                    height: 56,
                    child: _pending
                        ? OutlinedButton(
                            onPressed: widget.onCancel,
                            child: const Text('取消'),
                          )
                        : FilledButton(
                            onPressed: widget.onConnect == null
                                ? null
                                : _submit,
                            child: const Text('连接'),
                          ),
                  ),
                ],
              ),
            ),
            if (status != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Row(
                    children: [
                      if (failed) ...[
                        Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: palette.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: failed
                                ? palette.onErrorContainer
                                : palette.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hostsCard(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final hosts = widget.state.hosts;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: palette.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: palette.outlineVariant.withAlpha(110)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('附近主机', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (hosts.isEmpty && widget.onConnect != null)
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (hosts.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceContainerHighest.withAlpha(100),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.onConnect == null
                          ? Icons.hourglass_empty_rounded
                          : Icons.wifi_find_rounded,
                      color: palette.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.onConnect == null ? '客户端初始化中' : '正在搜索局域网',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: palette.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              for (var index = 0; index < hosts.length; index++) ...[
                _hostTile(context, hosts[index]),
                if (index != hosts.length - 1) const SizedBox(height: 7),
              ],
          ],
        ),
      ),
    );
  }

  Widget _hostTile(BuildContext context, Host host) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final canConnect = !_pending && !host.busy && widget.onConnect != null;
    return Semantics(
      button: canConnect,
      enabled: canConnect,
      label: '连接 ${host.name}',
      child: Material(
        color: palette.surfaceContainerHighest.withAlpha(105),
        borderRadius: BorderRadius.circular(13),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: canConnect
              ? () {
                  FocusScope.of(context).unfocus();
                  widget.onConnect!(host.address);
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    host.busy
                        ? Icons.computer_rounded
                        : Icons.computer_outlined,
                    size: 20,
                    color: host.busy
                        ? palette.onSurfaceVariant
                        : palette.primary,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        host.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        host.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (host.busy)
                  Text(
                    '忙碌',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: palette.tertiary,
                    ),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: canConnect
                        ? palette.primary
                        : palette.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          gradient: RadialGradient(
            center: const Alignment(-0.9, -1),
            radius: 1.15,
            colors: [palette.primary.withAlpha(19), palette.surface],
            stops: const [0, 0.62],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final split = constraints.maxWidth >= 860;
              final connect = _connectCard(context, compact: compact);
              final hosts = _hostsCard(context);
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 16 : 28,
                      compact ? 18 : 34,
                      compact ? 16 : 28,
                      28,
                    ),
                    children: [
                      _header(context, compact: compact),
                      SizedBox(height: compact ? 24 : 34),
                      if (!widget.state.discover || split)
                        split
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 5, child: connect),
                                  const SizedBox(width: 20),
                                  Expanded(flex: 4, child: hosts),
                                ],
                              )
                            : Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 680,
                                  ),
                                  child: connect,
                                ),
                              )
                      else ...[
                        connect,
                        const SizedBox(height: 14),
                        hosts,
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 21),
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          maximumSize: const Size(40, 40),
          backgroundColor: palette.surfaceContainerHigh.withAlpha(150),
          foregroundColor: palette.onSurfaceVariant,
        ),
      ),
    );
  }
}
