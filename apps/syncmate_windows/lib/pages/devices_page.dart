import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syncmate_core/syncmate_core.dart';

import '../theme.dart';
import 'audit_log_page.dart';

IconData _deviceIcon(String type) => switch (type) {
      'android' => Icons.phone_android_rounded,
      'ios' => Icons.phone_iphone_rounded,
      'linux' => Icons.computer_rounded,
      'macos' => Icons.desktop_mac_rounded,
      _ => Icons.desktop_windows_rounded,
    };

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.discovery,
    required this.trustStore,
    required this.connections,
    required this.self,
    this.auditLogPath,
  });

  final DiscoveryService discovery;
  final TrustStore trustStore;
  final ConnectionManager connections;
  final DeviceProfile self;
  final String? auditLogPath;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<DiscoveredDevice> _nearby = [];
  List<TrustedDevice> _trusted = [];
  final Set<String> _online = {};
  StreamSubscription<DiscoveryEvent>? _discoverySub;
  StreamSubscription<void>? _connectionsSub;

  @override
  void initState() {
    super.initState();
    _discoverySub = widget.discovery.events.listen(_onDiscoveryEvent);
    _connectionsSub = widget.connections.state.listen((_) {
      if (mounted) setState(() {});
    });
    _refreshTrusted();
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _connectionsSub?.cancel();
    super.dispose();
  }

  void _onDiscoveryEvent(DiscoveryEvent event) {
    if (!mounted) return;
    setState(() {
      _nearby = widget.discovery.devices;
      if (event is DeviceDiscovered) {
        _online.add(event.device.fingerprint);
      } else if (event is DeviceUpdated) {
        _online.add(event.device.fingerprint);
      } else if (event is DeviceExpired) {
        _online.remove(event.device.fingerprint);
      }
    });
  }

  Future<void> _refreshTrusted() async {
    final list = await widget.trustStore.load();
    if (!mounted) return;
    setState(() => _trusted = list);
  }

  Future<void> _requestConnect(DiscoveredDevice device) async {
    final client =
        SyncMateClient(baseUrl: device.baseUrl, fingerprint: widget.self.fingerprint);
    try {
      final info = await client.connect(widget.self);
      if (info.fingerprint != device.fingerprint) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接失败：对方身份与发现报文不符')),
        );
        return;
      }
      await widget.trustStore.addOrUpdate(TrustedDevice(
        fingerprint: info.fingerprint,
        alias: info.alias,
        deviceType: info.deviceType,
        port: info.port,
        lastConnected: DateTime.now(),
      ));
      _refreshTrusted();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已与「${info.alias}」建立信任')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.rejected
          ? '对方拒绝了连接请求'
          : e.code == ApiErrorCode.timeout
              ? '连接请求超时'
              : '连接失败：${e.message}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连接失败：无法访问对方设备')),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _connectLong(TrustedDevice device) async {
    final online = _online.contains(device.fingerprint);
    if (!online) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设备离线，无法建立连接')),
      );
      return;
    }
    await widget.connections.connect(device.fingerprint);
  }

  Future<void> _disconnectLong(TrustedDevice device) async {
    await widget.connections.disconnect(device.fingerprint);
  }

  Future<void> _revokeTrust(TrustedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销信任'),
        content: Text('确定撤销对「${device.alias}」的信任吗？撤销后对方需重新发起连接申请。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.connections.disconnect(device.fingerprint);
    await widget.trustStore.remove(device.fingerprint);
    _refreshTrusted();
  }

  Future<void> _renameTrust(TrustedDevice device) async {
    final controller = TextEditingController(text: device.alias);
    final newAlias = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名设备'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '别名'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final trimmed = newAlias?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == device.alias) return;
    await widget.trustStore.addOrUpdate(device.copyWith(alias: trimmed));
    _refreshTrusted();
  }

  void _openAuditLog() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AuditLogPage(logPath: widget.auditLogPath),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备管理'),
        actions: [
          IconButton(
            tooltip: '操作日志',
            icon: const Icon(Icons.receipt_long_rounded, size: 22),
            onPressed: _openAuditLog,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildTrustedPanel(context)),
            const SizedBox(width: 20),
            Expanded(child: _buildNearbyPanel(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildTrustedPanel(BuildContext context) {
    return _PanelCard(
      title: '已信任设备',
      count: _trusted.length,
      child: _trusted.isEmpty
          ? const EmptyState(
              icon: Icons.verified_user_outlined,
              title: '尚无信任设备',
              subtitle: '在右侧「附近设备」列表中发起连接',
            )
          : ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _trusted.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final device = _trusted[index];
                final online = _online.contains(device.fingerprint);
                final status = widget.connections.statusOf(device.fingerprint);
                final connected = status == ConnectionStatus.connected;
                final connecting = status == ConnectionStatus.connecting;
                return _DeviceCard(
                  icon: _deviceIcon(device.deviceType),
                  title: device.alias,
                  online: online,
                  subtitle: '${_connectionStatusLabel(status, online)}  ·  '
                      '最近连接：${_formatTime(device.lastConnected)}',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (connecting)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (connected)
                        OutlinedButton(
                          onPressed: () => _disconnectLong(device),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.danger,
                            side: const BorderSide(color: AppColors.danger),
                          ),
                          child: const Text('断开连接'),
                        )
                      else
                        FilledButton(
                          onPressed: online ? () => _connectLong(device) : null,
                          child: const Text('连接'),
                        ),
                      const SizedBox(width: 6),
                      _RoundIconButton(
                        icon: Icons.edit_rounded,
                        tooltip: '重命名',
                        onPressed: () => _renameTrust(device),
                      ),
                      const SizedBox(width: 6),
                      _RoundIconButton(
                        icon: Icons.link_off_rounded,
                        tooltip: '撤销信任',
                        danger: true,
                        onPressed: () => _revokeTrust(device),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildNearbyPanel(BuildContext context) {
    return _PanelCard(
      title: '附近设备',
      count: _nearby.length,
      child: _nearby.isEmpty
          ? const EmptyState(
              icon: Icons.wifi_find_rounded,
              title: '正在搜索同一局域网内的设备…',
              subtitle: '请确保对方设备已打开 SyncMate 并处于同一网络',
            )
          : ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _nearby.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final device = _nearby[index];
                final trusted = _trusted.any(
                  (d) => d.fingerprint == device.fingerprint,
                );
                return _DeviceCard(
                  icon: _deviceIcon(device.deviceType),
                  title: device.alias,
                  online: true,
                  subtitle: '${device.baseUrl}  ·  ${device.appVersion ?? ''}',
                  trailing: trusted
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.success.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: const Text(
                            '已信任',
                            style: TextStyle(
                              color: AppColors.success,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : FilledButton(
                          onPressed: () => _requestConnect(device),
                          child: const Text('请求连接'),
                        ),
                );
              },
            ),
    );
  }

  String _connectionStatusLabel(ConnectionStatus status, bool online) {
    if (status == ConnectionStatus.connected) return '已连接';
    if (status == ConnectionStatus.connecting) return '连接中…';
    if (!online) return '离线';
    return '未连接';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '从未';
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

/// 左右分栏面板卡片：标题 + 数量徽标 + 内容区。
class _PanelCard extends StatelessWidget {
  const _PanelCard({
    required this.title,
    required this.count,
    required this.child,
  });

  final String title;
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSunken,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 统一的设备卡片：图标块 + 在线状态点 + 标题/副标题 + 尾部操作区。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.online,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool online;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 21, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    StatusDot(online: online),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

/// 圆形小图标按钮，用于卡片尾部次要操作。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textSecondary;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onPressed,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: danger
                ? AppColors.danger.withValues(alpha: 0.08)
                : AppColors.surface,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}
