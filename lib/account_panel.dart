import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

typedef AccountTarget = ({String id, String name, bool online, bool busy});

class AccountPanel extends StatelessWidget {
  const AccountPanel({
    super.key,
    required this.server,
    required this.signedIn,
    required this.working,
    required this.enabled,
    required this.name,
    required this.code,
    required this.verificationUrl,
    required this.error,
    required this.hosts,
    required this.onSignIn,
    required this.onPasswordSignIn,
    required this.onCancel,
    required this.onSignOut,
    required this.onRefresh,
    required this.onConnect,
    required this.onServerChanged,
  });

  final Uri server;
  final bool signedIn, working, enabled;
  final String name, code, error;
  final Uri? verificationUrl;
  final List<AccountTarget> hosts;
  final VoidCallback onSignIn, onCancel, onSignOut, onRefresh;
  final Future<String?> Function(String email, String password)
  onPasswordSignIn;
  final ValueChanged<String> onConnect;
  final Future<String?> Function(String) onServerChanged;

  Future<void> _openApproval(BuildContext context) async {
    final url = verificationUrl;
    if (url == null) return;
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // Offer the same approval address through the clipboard.
    }
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('授权页面地址已复制。')));
    }
  }

  Future<void> _editServer(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _ServerDialog(initial: server.toString(), onSave: onServerChanged),
    );
  }

  Future<void> _openPasswordSignIn(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _PasswordSignInDialog(onSignIn: onPasswordSignIn),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_circle_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    signedIn && name.isNotEmpty ? name : 'RinCast 账号',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (signedIn)
                  IconButton(
                    tooltip: '刷新主机',
                    onPressed: working ? null : onRefresh,
                    icon: const Icon(Icons.refresh),
                  )
                else if (!working && code.isEmpty)
                  IconButton(
                    tooltip: '修改 RinCast 服务地址',
                    onPressed: () => _editServer(context),
                    icon: const Icon(Icons.settings_outlined),
                  ),
              ],
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  error,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (code.isNotEmpty) ...[
              const Text('在浏览器或主机上的 RinCast Streamer 确认此设备码。'),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      code,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制设备码',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: code)),
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: verificationUrl == null
                        ? null
                        : () => _openApproval(context),
                    child: const Text('打开授权页面'),
                  ),
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                ],
              ),
            ] else if (signedIn) ...[
              if (working) const LinearProgressIndicator(),
              if (hosts.isEmpty && !working)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('账号下暂无主机。请先在 Streamer 登录同一账号。'),
                ),
              for (final host in hosts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.computer_outlined),
                  title: Text(
                    host.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    host.busy ? '忙碌' : (host.online ? '在线' : '离线'),
                  ),
                  trailing: host.online && !host.busy
                      ? const Icon(Icons.chevron_right)
                      : null,
                  enabled: host.online && !host.busy && enabled && !working,
                  onTap: host.online && !host.busy && enabled && !working
                      ? () => onConnect(host.id)
                      : null,
                ),
              TextButton(onPressed: onSignOut, child: const Text('退出账号')),
            ] else if (working) ...[
              const LinearProgressIndicator(),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ] else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: enabled ? onSignIn : null,
                    child: const Text('登录 RinCast'),
                  ),
                  OutlinedButton(
                    onPressed: enabled
                        ? () => _openPasswordSignIn(context)
                        : null,
                    child: const Text('邮箱密码登录'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PasswordSignInDialog extends StatefulWidget {
  const _PasswordSignInDialog({required this.onSignIn});

  final Future<String?> Function(String email, String password) onSignIn;

  @override
  State<_PasswordSignInDialog> createState() => _PasswordSignInDialogState();
}

class _PasswordSignInDialogState extends State<_PasswordSignInDialog> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.onSignIn(_email.text.trim(), _password.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _submitting = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('邮箱密码登录'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                autofocus: true,
                enabled: !_submitting,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '邮箱'),
                validator: (_) => _email.text.trim().isEmpty ? '请输入邮箱。' : null,
                onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                focusNode: _passwordFocus,
                enabled: !_submitting,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: '密码'),
                validator: (_) => _password.text.isEmpty ? '请输入密码。' : null,
                onFieldSubmitted: (_) {
                  if (!_submitting) _submit();
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: const Text('登录'),
        ),
      ],
    );
  }
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.initial, required this.onSave});

  final String initial;
  final Future<String?> Function(String) onSave;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final _text = TextEditingController(text: widget.initial);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final error = await widget.onSave(_text.text.trim());
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('RinCast 服务地址'),
    content: TextField(
      controller: _text,
      autofocus: true,
      enabled: !_saving,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        hintText: 'https://rincast.com',
        errorText: _error,
      ),
      onSubmitted: (_) {
        if (!_saving) _save();
      },
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
    ],
  );
}
