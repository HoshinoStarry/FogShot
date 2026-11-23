import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'host_controller.dart';

Future<void> showHostDialog(BuildContext context, HostController host) =>
    showDialog<void>(context: context, builder: (_) => _HostDialog(host));

class _HostDialog extends StatelessWidget {
  const _HostDialog(this.host);

  final HostController host;

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '共享本机',
                    style: Theme.of(context).textTheme.titleLarge,
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
            child: ListenableBuilder(
              listenable: host,
              builder: (context, _) => SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _body(context),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final style = Theme.of(context);
    final phase = host.phase;
    final sharing = phase == SharingPhase.sharing;
    final idle = phase == SharingPhase.idle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.cast_rounded,
              color: sharing ? style.colorScheme.primary : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(switch (phase) {
                SharingPhase.idle => '共享已关闭',
                SharingPhase.starting => '正在启动…',
                SharingPhase.sharing =>
                  host.hostName.isEmpty ? '共享中' : host.hostName,
                SharingPhase.stopping => '正在停止…',
              }, style: style.textTheme.titleMedium),
            ),
            if (idle)
              FilledButton(onPressed: host.start, child: const Text('开始共享'))
            else if (phase != SharingPhase.stopping)
              OutlinedButton(
                onPressed: () => unawaited(host.stop()),
                child: const Text('停止共享'),
              ),
          ],
        ),
        if (host.error case final error?) ...[
          const SizedBox(height: 12),
          Text(error, style: TextStyle(color: style.colorScheme.error)),
        ],
        if (idle && Platform.isMacOS) ...[
          const SizedBox(height: 12),
          const Text('首次共享时，在系统设置中允许屏幕录制和辅助功能。'),
        ],
        if (sharing) ...[
          if (host.addresses.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('局域网地址', style: style.textTheme.labelMedium),
            for (final address in host.addresses) SelectableText(address),
          ],
          if (host.approval case final prompt?) ...[
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${prompt.name} 请求配对',
                      style: style.textTheme.titleSmall,
                    ),
                    if (prompt.address.isNotEmpty) Text(prompt.address),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => host.answer(prompt, allow: false),
                          child: const Text('拒绝'),
                        ),
                        OutlinedButton(
                          onPressed: () => host.answer(prompt, allow: true),
                          child: const Text('仅本次'),
                        ),
                        FilledButton.tonal(
                          onPressed: () =>
                              host.answer(prompt, allow: true, remember: true),
                          child: const Text('允许并记住'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (host.connectedDevice case final device?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices),
              title: Text(device),
              trailing: TextButton(
                onPressed: host.disconnect,
                child: const Text('断开'),
              ),
            ),
          if (host.trustedDevices.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('已记住的设备'),
              children: [
                for (final device in host.trustedDevices)
                  ListTile(
                    dense: true,
                    title: Text(device.name),
                    trailing: TextButton(
                      onPressed: host.updating
                          ? null
                          : () => host.removeTrusted(device),
                      child: const Text('撤销信任'),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('RinCast 主机账户'),
            subtitle: host.signedIn ? Text(host.accountName) : null,
            trailing: TextButton(
              onPressed: host.updating
                  ? null
                  : (host.signedIn ? host.signOut : () => _signIn(context)),
              child: Text(host.signedIn ? '退出' : '登录'),
            ),
          ),
          if (host.signedIn)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许跨网连接'),
              subtitle: host.allowRemote && host.cloudStatus == 'online'
                  ? const Text('在线')
                  : null,
              value: host.allowRemote,
              onChanged: host.updating
                  ? null
                  : (value) => host.updateSettings({'allowRemote': value}),
            ),
          OutlinedButton.icon(
            onPressed: host.updating ? null : () => _settings(context),
            icon: const Icon(Icons.settings_outlined),
            label: const Text('主机设置'),
          ),
        ],
      ],
    );
  }

  Future<void> _signIn(BuildContext context) async {
    final input = await showDialog<({String first, String second})>(
      context: context,
      builder: (_) => const _HostFields(credentials: true),
    );
    if (input != null) host.signIn(input.first, input.second);
  }

  Future<void> _settings(BuildContext context) async {
    final input = await showDialog<({String first, String second})>(
      context: context,
      builder: (_) => _HostFields(
        first: host.hostName,
        second: host.accountServer,
        serverEditable: !host.signedIn,
      ),
    );
    if (input != null) {
      host.updateSettings({
        'pcName': input.first,
        if (!host.signedIn && input.second != host.accountServer)
          'cloudUrl': input.second,
      });
    }
  }
}

class _HostFields extends StatefulWidget {
  const _HostFields({
    this.credentials = false,
    this.first = '',
    this.second = '',
    this.serverEditable = true,
  });

  final bool credentials, serverEditable;
  final String first, second;

  @override
  State<_HostFields> createState() => _HostFieldsState();
}

class _HostFieldsState extends State<_HostFields> {
  final _form = GlobalKey<FormState>();
  late final _first = TextEditingController(text: widget.first);
  late final _second = TextEditingController(text: widget.second);

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop((
      first: _first.text.trim(),
      second: widget.credentials ? _second.text : _second.text.trim(),
    ));
  }

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.credentials ? '登录主机账户' : '主机设置'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _first,
            decoration: InputDecoration(
              labelText: widget.credentials ? '邮箱' : '主机名称',
            ),
            keyboardType: widget.credentials
                ? TextInputType.emailAddress
                : TextInputType.text,
            validator: (value) =>
                (value?.trim().isEmpty ?? true) ? '不能为空' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _second,
            enabled: widget.credentials || widget.serverEditable,
            obscureText: widget.credentials,
            autocorrect: false,
            enableSuggestions: !widget.credentials,
            decoration: InputDecoration(
              labelText: widget.credentials ? '密码' : 'RinCast 服务地址',
            ),
            onFieldSubmitted: (_) => _submit(),
            validator: (value) {
              if (widget.credentials) {
                return (value?.isEmpty ?? true) ? '请输入密码' : null;
              }
              if (!widget.serverEditable) return null;
              final uri = Uri.tryParse(value?.trim() ?? '');
              return uri?.scheme == 'https' &&
                      uri!.host.isNotEmpty &&
                      uri.userInfo.isEmpty
                  ? null
                  : '请输入 HTTPS 地址';
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.credentials ? '登录' : '保存'),
      ),
    ],
  );
}
