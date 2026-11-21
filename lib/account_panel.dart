import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';

typedef AccountTarget = ({String id, String name, bool online, bool busy});

class AccountPanel extends StatefulWidget {
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
    this.accounts = const [],
    this.activeAccountId,
    required this.onSignIn,
    required this.onPasswordSignIn,
    required this.onCancel,
    required this.onSignOut,
    required this.onRefresh,
    required this.onConnect,
    required this.onServerChanged,
    this.onSelectAccount,
    this.onRemoveAccount,
    this.onConnectAccount,
  });

  final Uri server;
  final bool signedIn, working, enabled;
  final String name, code, error;
  final Uri? verificationUrl;
  final List<AccountTarget> hosts;
  final List<AccountProfile> accounts;
  final String? activeAccountId;
  final VoidCallback onSignIn, onCancel, onSignOut, onRefresh;
  final Future<String?> Function(String email, String password)
  onPasswordSignIn;
  final ValueChanged<String> onConnect;
  final Future<String?> Function(String) onServerChanged;
  final ValueChanged<String>? onSelectAccount;
  final Future<String?> Function(String accountId)? onRemoveAccount;
  final void Function(String accountId, String pcId)? onConnectAccount;

  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  bool _expanded = true;
  bool _autoOpenApprovalPending = false;
  bool _approvalWasAutoOpened = false;

  @override
  void didUpdateWidget(AccountPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.signedIn && !oldWidget.signedIn) ||
        (_hasAccounts && oldWidget.accounts.isEmpty) ||
        (widget.working && !oldWidget.working) ||
        (widget.code.isNotEmpty && oldWidget.code.isEmpty) ||
        (widget.error.isNotEmpty && oldWidget.error.isEmpty)) {
      _expanded = true;
    }
    if (oldWidget.code.isNotEmpty && widget.code.isEmpty) {
      _approvalWasAutoOpened = false;
    }
    if (_autoOpenApprovalPending) {
      final signInEndedWithoutCode =
          oldWidget.working && !widget.working && widget.code.isEmpty;
      if (signInEndedWithoutCode ||
          (!widget.working && widget.code.isEmpty && widget.error.isNotEmpty)) {
        _autoOpenApprovalPending = false;
      } else {
        _scheduleAutomaticApproval();
      }
    }
  }

  Future<void> _openApproval(
    BuildContext context, {
    bool automatic = false,
  }) async {
    final url = widget.verificationUrl;
    if (url == null) return;
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // Offer the same approval address through the clipboard.
    }
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(automatic ? '无法直接打开浏览器，授权地址已复制。' : '授权页面地址已复制。'),
        ),
      );
    }
  }

  void _startDeviceSignIn() {
    setState(() {
      _expanded = true;
      _autoOpenApprovalPending = true;
    });
    widget.onSignIn();
  }

  void _scheduleAutomaticApproval() {
    final url = widget.verificationUrl;
    final code = widget.code;
    if (!_autoOpenApprovalPending ||
        url == null ||
        url.scheme != 'https' ||
        code.isEmpty) {
      return;
    }
    _autoOpenApprovalPending = false;
    _approvalWasAutoOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.code != code || widget.verificationUrl != url) {
        return;
      }
      unawaited(_openApproval(context, automatic: true));
    });
  }

  Future<void> _editServer(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ServerDialog(
        initial: widget.server.toString(),
        onSave: widget.onServerChanged,
      ),
    );
  }

  Future<void> _openPasswordSignIn(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) =>
          _PasswordSignInDialog(onSignIn: widget.onPasswordSignIn),
    );
  }

  Future<void> _removeAccount(AccountProfile account) async {
    final remove = widget.onRemoveAccount;
    if (remove == null) return;
    final label = account.name.isNotEmpty ? account.name : account.email;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除 RinCast 账户'),
        content: Text('将从此设备移除“$label”及其登录令牌。其他账户的设备不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await remove(account.id);
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  bool get _hasAccounts => widget.accounts.isNotEmpty;

  String get _summaryStatus {
    if (widget.code.isNotEmpty) return '等待设备码确认';
    if (_hasAccounts) {
      final hosts = widget.accounts.expand((account) => account.hosts);
      final total = hosts.length;
      final online = hosts.where((host) => host.online).length;
      if (widget.working) return '${widget.accounts.length} 个账户 · 正在更新设备';
      return '${widget.accounts.length} 个账户 · $online/$total 台设备在线';
    }
    if (widget.working) {
      return widget.signedIn ? '正在更新主机' : '正在登录';
    }
    if (widget.signedIn) {
      if (widget.error.isNotEmpty) return '账号需要处理';
      final online = widget.hosts.where((host) => host.online).length;
      if (online == 0) return '${widget.hosts.length} 台主机';
      return '$online 台在线 · ${widget.hosts.length} 台主机';
    }
    if (widget.error.isNotEmpty) return '登录失败';
    return '登录以连接账号主机';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final active =
        widget.signedIn ||
        _hasAccounts ||
        widget.working ||
        widget.code.isNotEmpty;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: palette.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.outlineVariant.withAlpha(115)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: active
                            ? palette.primary.withAlpha(30)
                            : palette.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        widget.signedIn || _hasAccounts
                            ? Icons.account_circle_rounded
                            : Icons.person_outline_rounded,
                        size: 21,
                        color: active
                            ? palette.primary
                            : palette.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (widget.signedIn || _hasAccounts) &&
                                    widget.name.isNotEmpty
                                ? widget.name
                                : 'RinCast 账户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _summaryStatus,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: widget.error.isNotEmpty
                                  ? palette.error
                                  : palette.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.working) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.primary,
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: palette.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(
                        height: 1,
                        color: palette.outlineVariant.withAlpha(105),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
                        child: _expandedContent(context),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _expandedContent(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final serverEditable = !widget.working && widget.code.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.error.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: palette.errorContainer.withAlpha(145),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 17,
                  color: palette.onErrorContainer,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (widget.code.isNotEmpty)
          _approvalContent(context)
        else if (widget.signedIn || _hasAccounts)
          _signedInContent(context)
        else if (widget.working)
          _waitingContent(context)
        else
          _signInContent(context),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 16, color: palette.onSurfaceVariant),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                widget.server.toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: '修改 RinCast 服务地址',
              visualDensity: VisualDensity.compact,
              onPressed: serverEditable ? () => _editServer(context) : null,
              icon: const Icon(Icons.settings_outlined, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  Widget _approvalContent(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '设备码',
          style: theme.textTheme.labelMedium?.copyWith(
            color: palette.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                widget.code,
                style: theme.textTheme.headlineSmall?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '复制设备码',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: widget.code)),
              icon: const Icon(Icons.copy_rounded, size: 19),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            FilledButton.tonalIcon(
              onPressed: widget.verificationUrl == null
                  ? null
                  : () => _openApproval(context),
              icon: const Icon(Icons.open_in_browser_rounded, size: 18),
              label: Text(_approvalWasAutoOpened ? '重新打开浏览器' : '打开浏览器'),
            ),
            TextButton(onPressed: widget.onCancel, child: const Text('取消')),
          ],
        ),
      ],
    );
  }

  Widget _signedInContent(BuildContext context) {
    if (_hasAccounts) return _accountsContent(context);
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('账号主机', style: theme.textTheme.titleSmall),
            const Spacer(),
            IconButton(
              tooltip: '刷新主机',
              visualDensity: VisualDensity.compact,
              onPressed: widget.working ? null : widget.onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 19),
            ),
          ],
        ),
        if (widget.working)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(
              minHeight: 2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        if (widget.hosts.isEmpty && !widget.working)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: palette.surfaceContainerHighest.withAlpha(90),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '暂无账号主机',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.onSurfaceVariant,
              ),
            ),
          )
        else
          for (var index = 0; index < widget.hosts.length; index++) ...[
            _accountHostTile(context, widget.hosts[index]),
            if (index != widget.hosts.length - 1) const SizedBox(height: 5),
          ],
        const SizedBox(height: 10),
        _addAccountControls(context),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onSignOut,
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('退出账号'),
          ),
        ),
      ],
    );
  }

  Widget _accountsContent(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('账户与设备', style: theme.textTheme.titleSmall),
            const Spacer(),
            IconButton(
              tooltip: '刷新全部账户设备',
              visualDensity: VisualDensity.compact,
              onPressed: widget.working ? null : widget.onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 19),
            ),
          ],
        ),
        if (widget.working)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(
              minHeight: 2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        for (var index = 0; index < widget.accounts.length; index++) ...[
          _accountSection(context, widget.accounts[index]),
          if (index != widget.accounts.length - 1) const SizedBox(height: 8),
        ],
        const SizedBox(height: 10),
        _addAccountControls(context),
        if (widget.activeAccountId != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('退出当前账户'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _accountSection(BuildContext context, AccountProfile account) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final active = account.id == widget.activeAccountId || account.active;
    final online = account.hosts.where((host) => host.online).length;
    final status = account.loadingHosts
        ? '正在更新设备'
        : account.error != null
        ? '账户需要处理'
        : '$online/${account.hosts.length} 台设备在线';
    final canSelect = widget.onSelectAccount != null && !active;
    final label = account.name.isNotEmpty ? account.name : account.email;
    return Material(
      color: palette.surfaceContainerHighest.withAlpha(80),
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: canSelect ? () => widget.onSelectAccount!(account.id) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 7, 5, 7),
              child: Row(
                children: [
                  Icon(
                    active
                        ? Icons.check_circle_rounded
                        : Icons.account_circle_outlined,
                    size: 20,
                    color: active ? palette.primary : palette.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (active) ...[
                              const SizedBox(width: 6),
                              _StatusPill(label: '当前'),
                            ],
                          ],
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '${account.server.host} · $status',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: account.error == null
                                ? palette.onSurfaceVariant
                                : palette.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (account.loadingHosts)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (widget.onRemoveAccount != null)
                    PopupMenuButton<String>(
                      tooltip: '管理账户',
                      enabled: !widget.working,
                      onSelected: (_) => unawaited(_removeAccount(account)),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'remove', child: Text('移除账户')),
                      ],
                      icon: const Icon(Icons.more_vert_rounded, size: 19),
                    ),
                ],
              ),
            ),
          ),
          if (account.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(37, 0, 10, 6),
              child: Text(
                account.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.error,
                ),
              ),
            ),
          Divider(
            height: 1,
            indent: 9,
            endIndent: 9,
            color: palette.outlineVariant.withAlpha(80),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 6),
            child: account.hosts.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(4, 5, 4, 6),
                    child: Text(
                      account.loadingHosts ? '正在获取设备…' : '暂无可用设备',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.onSurfaceVariant,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (
                        var index = 0;
                        index < account.hosts.length;
                        index++
                      ) ...[
                        _accountHostTile(
                          context,
                          (
                            id: account.hosts[index].id,
                            name: account.hosts[index].name,
                            online: account.hosts[index].online,
                            busy: account.hosts[index].busy,
                          ),
                          accountId: account.id,
                          accountBusy: account.loadingHosts,
                        ),
                        if (index != account.hosts.length - 1)
                          const SizedBox(height: 4),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _addAccountControls(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 7,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text('添加账户', style: Theme.of(context).textTheme.labelMedium),
      FilledButton.tonalIcon(
        onPressed: widget.enabled && !widget.working
            ? _startDeviceSignIn
            : null,
        icon: const Icon(Icons.qr_code_2_rounded, size: 17),
        label: const Text('设备码'),
      ),
      OutlinedButton.icon(
        onPressed: widget.enabled && !widget.working
            ? () => _openPasswordSignIn(context)
            : null,
        icon: const Icon(Icons.mail_outline_rounded, size: 17),
        label: const Text('密码'),
      ),
    ],
  );

  Widget _accountHostTile(
    BuildContext context,
    AccountTarget host, {
    String? accountId,
    bool accountBusy = false,
  }) {
    final enabled =
        host.online &&
        !host.busy &&
        widget.enabled &&
        !accountBusy &&
        (accountId != null || !widget.working);
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final status = host.busy ? '忙碌' : (host.online ? '在线' : '离线');
    return Material(
      key: ValueKey('${accountId ?? ''}\u0000${host.id}'),
      color: palette.surfaceContainerHighest.withAlpha(95),
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        enabled: enabled,
        contentPadding: const EdgeInsets.fromLTRB(9, 0, 7, 0),
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
        leading: Icon(
          Icons.computer_outlined,
          size: 20,
          color: enabled ? palette.primary : palette.onSurfaceVariant,
        ),
        title: Text(
          host.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          status,
          style: theme.textTheme.bodySmall?.copyWith(
            color: host.busy ? palette.tertiary : palette.onSurfaceVariant,
          ),
        ),
        trailing: enabled
            ? Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: palette.primary,
              )
            : null,
        onTap: enabled
            ? () {
                final connectAccount = widget.onConnectAccount;
                if (accountId != null && connectAccount != null) {
                  connectAccount(accountId, host.id);
                } else {
                  widget.onConnect(host.id);
                }
              }
            : null,
      ),
    );
  }

  Widget _waitingContent(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: LinearProgressIndicator(minHeight: 2)),
        const SizedBox(width: 10),
        TextButton(onPressed: widget.onCancel, child: const Text('取消')),
      ],
    );
  }

  Widget _signInContent(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: widget.enabled ? _startDeviceSignIn : null,
          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
          label: const Text('设备码登录'),
        ),
        OutlinedButton.icon(
          onPressed: widget.enabled ? () => _openPasswordSignIn(context) : null,
          icon: const Icon(Icons.mail_outline_rounded, size: 18),
          label: const Text('邮箱密码登录'),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: palette.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: palette.onPrimaryContainer),
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
