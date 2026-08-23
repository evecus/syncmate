import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:syncmate_core/syncmate_core.dart';

import '../platform/foreground_service.dart';
import '../platform/storage_permission.dart';
import '../platform/system_clipboard_backend.dart';
import '../theme.dart';
import 'devices_page.dart';

/// 单个视图的槽位：source 为 null 表示本机，否则为设备指纹。
class _PaneSlot {
  String? source;
  String? path;
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.server,
    required this.discovery,
    required this.trustStore,
    required this.connections,
    required this.self,
    this.auditLogPath,
  });

  final SyncMateServer server;
  final DiscoveryService discovery;
  final TrustStore trustStore;
  final ConnectionManager connections;
  final DeviceProfile self;
  final String? auditLogPath;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<TrustedDevice> _trusted = [];
  final Set<String> _online = {};
  StreamSubscription<DiscoveryEvent>? _discoverySub;
  StreamSubscription<ConnectRequest>? _connectSub;
  StreamSubscription<TransferEvent>? _transferSub;
  bool _requestDialogVisible = false;
  bool? _storageGranted;

  late final TransferService _transfers;
  late final SystemClipboardBackend _clipboardBackend;
  ClipboardService? _clipboardService;
  StreamSubscription<void>? _clipboardSub;
  StreamSubscription<void>? _connectionsSub;
  bool _serviceRunning = false;

  final LocalFileSystemAdapter _fs = LocalFileSystemAdapter();
  final _PaneSlot _paneA = _PaneSlot();
  final _PaneSlot _paneB = _PaneSlot();
  final GlobalKey<_FilePaneState> _paneAKey = GlobalKey<_FilePaneState>();
  final GlobalKey<_FilePaneState> _paneBKey = GlobalKey<_FilePaneState>();

  /// 当前"批次"内的任务 id：弹窗展示的就是这批。用户关闭弹窗时，
  /// 已完成/失败/取消的任务从批次中移除；仍在跑的任务保留，
  /// 下次有新任务时会连同它一起在新弹窗里再次出现。
  final Set<String> _transferBatch = {};
  bool _transferDialogOpen = false;

  /// 当前焦点视图（左/右），决定顶部标题栏下方显示哪一侧的路径。
  bool _focusIsPaneA = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transfers = TransferService(self: widget.self);
    _clipboardBackend = SystemClipboardBackend();
    _clipboardService = ClipboardService(
      self: widget.self,
      trustStore: widget.trustStore,
      discovery: widget.discovery,
      backend: _clipboardBackend,
      serverEvents: widget.server.clipboardEvents,
    );
    _clipboardSub = _clipboardService!.state.listen((_) {
      if (!mounted) return;
      setState(() {});
      _syncForegroundService();
    });
    // 无需手动开关：始终尝试与在线信任设备建立连接（剪切板同步随连接自动生效）。
    _clipboardService!.setEnabled(true);
    _discoverySub = widget.discovery.events.listen(_onDiscoveryEvent);
    _connectSub = widget.server.connectRequests.listen(_onConnectRequest);
    _transferSub = _transfers.events.listen(_onTransferEvent);
    _connectionsSub = widget.connections.state.listen((_) {
      if (!mounted) return;
      setState(_resetDisconnectedPanes);
      _syncForegroundService();
    });
    _refreshTrusted();
    _checkStoragePermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _discoverySub?.cancel();
    _connectSub?.cancel();
    _transferSub?.cancel();
    _clipboardSub?.cancel();
    _connectionsSub?.cancel();
    unawaited(_clipboardService?.dispose());
    _transfers.dispose();
    if (_serviceRunning) unawaited(ForegroundService.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStoragePermission();
    }
    // 切前台/后台时都重新核对：只有连接上其他设备才保留前台服务保活；
    // 无连接时切后台直接放弃前台服务，交由系统按需回收进程。
    _syncForegroundService();
  }

  /// 依据当前是否与其他设备建立了连接（剪切板 WS 会话或设备长连接）决定
  /// 前台服务的启停。应用在前台时不需要前台服务保活；只有切到后台且
  /// 存在连接时才需要。
  Future<void> _syncForegroundService() async {
    final clipboardConnected =
        (_clipboardService?.connectedFingerprints.length ?? 0) > 0;
    final deviceConnected = widget.connections.connectedFingerprints.isNotEmpty;
    final connected = clipboardConnected || deviceConnected;
    final inBackground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    final shouldRun = connected && inBackground;
    if (shouldRun == _serviceRunning) return;
    _serviceRunning = shouldRun;
    if (shouldRun) {
      await ForegroundService.start();
    } else {
      await ForegroundService.stop();
    }
  }

  /// 新任务加入当前批次；若弹窗尚未打开则打开。已打开时新任务会
  /// 自动追加显示（弹窗内部监听同一 events 流）。
  void _onTransferEvent(TransferEvent event) {
    if (!mounted) return;
    if (event is TaskAdded) {
      _transferBatch.add(event.task.id);
      if (!_transferDialogOpen) {
        _transferDialogOpen = true;
        unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _TransferDialog(
            transfers: _transfers,
            batch: _transferBatch,
          ),
        ).then((_) {
          _transferDialogOpen = false;
          // 关闭后清理：已完成/失败/取消的任务移出批次；仍在跑的保留，
          // 便于下次新任务弹窗时一并展示。
          _transferBatch.removeWhere((id) {
            final task = _transfers.tasks.where((t) => t.id == id);
            if (task.isEmpty) return true;
            return task.first.status != TransferStatus.running;
          });
        }));
      }
    }
  }

  Future<void> _checkStoragePermission() async {
    final granted = await StoragePermission.isGranted();
    if (!mounted || granted == _storageGranted) return;
    setState(() => _storageGranted = granted);
  }

  Future<void> _grantStoragePermission() async {
    final granted = await StoragePermission.request();
    if (!mounted) return;
    setState(() => _storageGranted = granted);
    _showMessage(
      granted ? '文件访问权限已授予' : '请在系统设置中开启「允许访问所有文件」',
    );
  }

  void _onDiscoveryEvent(DiscoveryEvent event) {
    if (!mounted) return;
    setState(() {
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

  Future<void> _onConnectRequest(ConnectRequest request) async {
    if (_requestDialogVisible) return;
    _requestDialogVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.link_rounded, size: 16, color: AppColors.primary),
            ),
            const SizedBox(width: 10),
            const Text('连接请求'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, height: 1.4),
                children: [
                  TextSpan(
                    text: request.remote.alias,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(text: ' 请求与您的设备建立信任连接'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceSunken,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '同意后对方可浏览、修改、删除本机全部文件',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '身份 ID：${request.remote.fingerprint}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              request.reject();
            },
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              request.accept();
              _refreshTrusted();
            },
            child: const Text('允许'),
          ),
        ],
      ),
    );
    _requestDialogVisible = false;
  }

  Future<void> _openDevicesPage() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DevicesPage(
        discovery: widget.discovery,
        trustStore: widget.trustStore,
        connections: widget.connections,
        self: widget.self,
        auditLogPath: widget.auditLogPath,
      ),
    ));
    _refreshTrusted();
  }

  DiscoveredDevice? _onlineDevice(String fingerprint) {
    for (final device in widget.discovery.devices) {
      if (device.fingerprint == fingerprint) return device;
    }
    return null;
  }

  /// 已建立长连接的在线设备；未连接（即使在线可发现）一律视为不可用。
  DiscoveredDevice? _connectedDevice(String fingerprint) {
    if (!widget.connections.isConnected(fingerprint)) return null;
    return _onlineDevice(fingerprint);
  }

  /// 视图来源下拉项：本机 + 已建立长连接的已信任设备。
  ///
  /// 未连接的已信任设备不出现在此列表——所有文件浏览/传输都要求先
  /// 处于已连接状态，因此不允许把它们选作视图来源。
  List<({String? fingerprint, String alias})> _paneSources() {
    final list = <({String? fingerprint, String alias})>[
      (fingerprint: null, alias: '本机'),
    ];
    for (final trusted in _trusted) {
      if (!widget.connections.isConnected(trusted.fingerprint)) continue;
      final device = _onlineDevice(trusted.fingerprint);
      final alias = device?.alias ?? trusted.alias;
      list.add((fingerprint: trusted.fingerprint, alias: '● $alias'));
    }
    return list;
  }

  /// 视图正在浏览的设备一旦断开长连接，该视图自动切回本机，
  /// 避免停留在一个已不可用的来源上。
  void _resetDisconnectedPanes() {
    for (final pane in [_paneA, _paneB]) {
      final source = pane.source;
      if (source != null && !widget.connections.isConnected(source)) {
        pane.source = null;
        pane.path = null;
      }
    }
  }

  /// 当前焦点视图的来源别名（本机 / 设备名）。
  String _focusedSourceLabel() {
    final slot = _focusIsPaneA ? _paneA : _paneB;
    if (slot.source == null) return '本机';
    final device = _onlineDevice(slot.source!);
    if (device != null) return device.alias;
    for (final trusted in _trusted) {
      if (trusted.fingerprint == slot.source) return trusted.alias;
    }
    return '离线设备';
  }

  /// 当前焦点视图的路径（根目录时显示"(根目录)"）。
  String _focusedPathLabel() {
    final slot = _focusIsPaneA ? _paneA : _paneB;
    return slot.path ?? '(根目录)';
  }

  void _setFocus(bool isPaneA) {
    if (_focusIsPaneA == isPaneA) return;
    setState(() => _focusIsPaneA = isPaneA);
  }

  void _reloadPanes() {
    _paneAKey.currentState?.reload();
    _paneBKey.currentState?.reload();
  }

  String _remoteJoin(DiscoveredDevice device, String dir, String name) {
    final context_ = device.deviceType == 'windows' ? p.windows : p.posix;
    return context_.join(dir, name);
  }

  Future<bool> _awaitTask(TransferTask task) async {
    while (task.status == TransferStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return task.status == TransferStatus.done;
  }

  /// 复制/移动到另一视图的当前目录。
  Future<void> _transferFrom({
    required _PaneSlot from,
    required _PaneSlot to,
    required FileEntry entry,
    required String fullPath,
    required bool move,
  }) async {
    final target = to.path;
    if (target == null) {
      _showMessage('请先在目标视图进入目标文件夹');
      return;
    }
    final fromRemote = from.source != null;
    final toRemote = to.source != null;
    try {
      if (!fromRemote && !toRemote) {
        // 本机 → 本机
        final dst = p.join(target, entry.name);
        if (move) {
          await _fs.move(fullPath, dst);
          _showMessage('已移动');
        } else {
          final actual = await _fs.copy(fullPath, dst);
          _showMessage('已复制到 $actual');
        }
        _reloadPanes();
        return;
      }
      if (fromRemote && toRemote) {
        if (from.source == to.source) {
          // 同一设备：服务端复制/移动
          final device = _connectedDevice(from.source!);
          if (device == null) {
            _showMessage('对方设备未连接');
            return;
          }
          final client = SyncMateClient(
            baseUrl: device.baseUrl,
            fingerprint: widget.self.fingerprint,
          );
          final dst = _remoteJoin(device, target, entry.name);
          if (move) {
            final actual = await client.move(fullPath, dst);
            _showMessage('已移动至 $actual');
          } else {
            final actual = await client.copy(fullPath, dst);
            _showMessage('已复制到 $actual');
          }
          _reloadPanes();
          return;
        }
        // 不同设备：本机中转
        final fromDev = _connectedDevice(from.source!);
        final toDev = _connectedDevice(to.source!);
        if (fromDev == null || toDev == null) {
          _showMessage('对方设备未连接');
          return;
        }
        await _transfers.copyBetweenDevices(
          from: fromDev,
          fromPath: fullPath,
          to: toDev,
          toPath: _remoteJoin(toDev, target, entry.name),
          move: move,
        );
        _showMessage(move ? '已开始移动' : '已开始复制');
        return;
      }
      // 本机 ↔ 设备
      final device = toRemote ? _connectedDevice(to.source!) : _connectedDevice(from.source!);
      if (device == null) {
        _showMessage('对方设备未连接');
        return;
      }
      final remotePath =
          toRemote ? _remoteJoin(device, target, entry.name) : fullPath;
      final localPath =
          toRemote ? fullPath : p.join(target, entry.name);
      final task = entry.isDir
          ? await _transfers.copyDirectory(
              device: device,
              remotePath: remotePath,
              localPath: localPath,
              toRemote: toRemote,
            )
          : await _transfers.copy(
              device: device,
              remotePath: remotePath,
              localPath: localPath,
              toRemote: toRemote,
            );
      if (!move) {
        _showMessage('已开始复制');
        return;
      }
      final done = await _awaitTask(task);
      if (!done) {
        _showMessage('移动失败，源文件未删除');
        return;
      }
      if (fromRemote) {
        final fromClient = SyncMateClient(
          baseUrl: device.baseUrl,
          fingerprint: widget.self.fingerprint,
        );
        await fromClient.delete(fullPath, recursive: true);
      } else {
        await _fs.delete(fullPath, recursive: true);
      }
      _showMessage('已移动');
      _reloadPanes();
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
    } on Object catch (e) {
      _showMessage('操作失败：$e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final connectedCount = _clipboardService?.connectedFingerprints.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: AppColors.gradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.sync_alt_rounded,
                  size: 18, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Text('SyncMate'),
          ],
        ),
        actions: [
          _ConnectionBadge(connectedCount: connectedCount),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '设备管理',
            icon: const Icon(Icons.devices_rounded, size: 22),
            onPressed: _openDevicesPage,
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_focusedSourceLabel()} · ${_focusedPathLabel()}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _buildStorageBanner(context),
          Expanded(child: _buildFileManager(context)),
        ],
      ),
    );
  }

  Widget _buildStorageBanner(BuildContext context) {
    if (_storageGranted == null || _storageGranted!) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder_off_rounded,
                size: 18, color: AppColors.warning),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '未授予文件访问权限，本机及对方设备均无法访问本机文件',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
            ),
            TextButton(
              onPressed: _grantStoragePermission,
              style: TextButton.styleFrom(foregroundColor: AppColors.warning),
              child: const Text('去授权'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileManager(BuildContext context) {
    final sources = _paneSources();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _setFocus(true),
              child: _FilePane(
                key: _paneAKey,
                self: widget.self,
                source: _paneA.source,
                device: _connectedDevice(_paneA.source ?? ''),
                sources: sources,
                focused: _focusIsPaneA,
                onSourceChanged: (fp) => setState(() {
                  _paneA.source = fp;
                  _paneA.path = null;
                  _focusIsPaneA = true;
                }),
                onPathChanged: (path) => setState(() {
                  _paneA.path = path;
                  _focusIsPaneA = true;
                }),
                onTransferRequested: (entry, fullPath, move) =>
                    _transferFrom(
                        from: _paneA, to: _paneB, entry: entry, fullPath: fullPath, move: move),
              ),
            ),
          ),
          const _PaneDivider(),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _setFocus(false),
              child: _FilePane(
                key: _paneBKey,
                self: widget.self,
                source: _paneB.source,
                device: _connectedDevice(_paneB.source ?? ''),
                sources: sources,
                focused: !_focusIsPaneA,
                onSourceChanged: (fp) => setState(() {
                  _paneB.source = fp;
                  _paneB.path = null;
                  _focusIsPaneA = false;
                }),
                onPathChanged: (path) => setState(() {
                  _paneB.path = path;
                  _focusIsPaneA = false;
                }),
                onTransferRequested: (entry, fullPath, move) =>
                    _transferFrom(
                        from: _paneB, to: _paneA, entry: entry, fullPath: fullPath, move: move),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// AppBar 上的连接状态徽标：圆角胶囊，在线时显示已连接数量。
class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.connectedCount});

  final int connectedCount;

  @override
  Widget build(BuildContext context) {
    final connected = connectedCount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: connected
            ? AppColors.success.withValues(alpha: 0.10)
            : AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(online: connected, size: 7),
          const SizedBox(width: 6),
          Text(
            connected ? '$connectedCount 台在线' : '未连接',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: connected ? AppColors.success : AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 两个文件面板之间的竖向分隔：一条极细的渐变"同步管道"，
/// 呼应产品的双向同步主题，而非生硬的分割线。
class _PaneDivider extends StatelessWidget {
  const _PaneDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 17,
      child: Center(
        child: Container(
          width: 3,
          margin: const EdgeInsets.symmetric(vertical: 32),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.border,
                AppColors.primary.withValues(alpha: 0.25),
                AppColors.border,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 传输任务弹窗：开始传输时自动弹出（模态），展示当前批次内的所有任务。
/// 每个任务有独立的"停止"按钮（仅运行中可用）；弹窗只有一个"关闭"按钮，
/// 仅关闭弹窗本身，不影响仍在后台运行的任务。
class _TransferDialog extends StatefulWidget {
  const _TransferDialog({required this.transfers, required this.batch});

  final TransferService transfers;
  final Set<String> batch;

  @override
  State<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<_TransferDialog> {
  StreamSubscription<TransferEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.transfers.events.listen((event) {
      if (!mounted) return;
      if (event is TaskAdded) widget.batch.add(event.task.id);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<TransferTask> get _visibleTasks => widget.transfers.tasks
      .where((t) => widget.batch.contains(t.id))
      .toList();

  @override
  Widget build(BuildContext context) {
    final tasks = _visibleTasks;
    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.sync_alt_rounded,
                size: 16, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          const Text('传输任务'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      content: SizedBox(
        width: double.maxFinite,
        child: tasks.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Text('暂无任务', style: TextStyle(color: AppColors.textTertiary)),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tasks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 14),
                  itemBuilder: (context, index) =>
                      _buildTaskRow(context, tasks[index]),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildTaskRow(BuildContext context, TransferTask task) {
    final running = task.status == TransferStatus.running;
    final icon = switch (task.status) {
      TransferStatus.running => Icons.sync_rounded,
      TransferStatus.done => Icons.check_circle_rounded,
      TransferStatus.failed => Icons.error_rounded,
      TransferStatus.cancelled => Icons.cancel_rounded,
    };
    final color = switch (task.status) {
      TransferStatus.running => AppColors.primary,
      TransferStatus.done => AppColors.success,
      TransferStatus.failed => AppColors.danger,
      TransferStatus.cancelled => AppColors.textTertiary,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (running)
                IconButton(
                  tooltip: '停止',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.stop_circle_outlined, size: 20),
                  color: AppColors.textSecondary,
                  onPressed: () => task.cancelToken.cancel(),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (running) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: task.progress.clamp(0.0, 1.0).toDouble(),
                minHeight: 5,
                backgroundColor: AppColors.border,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${formatBytes(task.done)}/${formatBytes(task.total)}'
              '${task.speed > 0 ? ' · ${formatBytes(task.speed.toInt())}/s' : ''}',
              style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ] else
            Text(
              switch (task.status) {
                TransferStatus.failed => '失败：${task.error}',
                TransferStatus.cancelled => '已取消',
                _ => '完成${task.finalRemotePath != null ? '（${task.finalRemotePath}）' : ''}',
              },
              style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
        ],
      ),
    );
  }
}

/// 文件浏览视图：来源可切换（本机 / 任意在线信任设备）。
class _FilePane extends StatefulWidget {
  const _FilePane({
    super.key,
    required this.self,
    required this.source,
    required this.device,
    required this.sources,
    required this.onSourceChanged,
    required this.onPathChanged,
    required this.onTransferRequested,
    this.focused = false,
  });

  final DeviceProfile self;

  /// null = 本机；否则为设备指纹。
  final String? source;
  final DiscoveredDevice? device;
  final List<({String? fingerprint, String alias})> sources;
  final ValueChanged<String?> onSourceChanged;
  final ValueChanged<String?> onPathChanged;
  final void Function(FileEntry entry, String fullPath, bool move)
      onTransferRequested;
  final bool focused;

  @override
  State<_FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends State<_FilePane> {
  final LocalFileSystemAdapter _fs = LocalFileSystemAdapter();
  String? _path;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  SyncMateClient? _client;
  late p.Context _remotePath;

  bool get _isRemote => widget.source != null;

  @override
  void initState() {
    super.initState();
    _remotePath =
        widget.device?.deviceType == 'windows' ? p.windows : p.posix;
    _load();
  }

  @override
  void didUpdateWidget(covariant _FilePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source ||
        widget.device?.fingerprint != oldWidget.device?.fingerprint) {
      _path = null;
      _client = null;
      _remotePath =
          widget.device?.deviceType == 'windows' ? p.windows : p.posix;
      _load();
    }
  }

  void reload() => _load();

  String _join(String dir, String name) =>
      _isRemote ? _remotePath.join(dir, name) : p.join(dir, name);

  String _joinCurrent(String name) => _join(_path ?? '', name);

  Future<void> _load() async {
    if (_isRemote) {
      await _loadRemote();
    } else {
      await _loadLocal();
    }
  }

  Future<void> _loadRemote() async {
    final device = widget.device;
    if (device == null) {
      setState(() {
        _loading = false;
        _error = '设备离线';
        _entries = [];
      });
      widget.onPathChanged(null);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = _client ??= SyncMateClient(
      baseUrl: device.baseUrl,
      fingerprint: widget.self.fingerprint,
    );
    try {
      final list = _path == null
          ? await client.listRoots()
          : await client.listFiles(_path!);
      if (!mounted) return;
      setState(() {
        _entries = list.entries;
        _loading = false;
      });
      widget.onPathChanged(
        _path ?? (_entries.isEmpty ? null : _entries.first.name),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = '无法访问对方设备';
        _loading = false;
      });
    }
  }

  Future<void> _loadLocal() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = _path == null ? await _fs.roots() : await _fs.list(_path!);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      widget.onPathChanged(
        _path ?? (_entries.isEmpty ? null : _entries.first.name),
      );
    } on FsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = '无法读取本机目录';
        _loading = false;
      });
    }
  }

  void _enter(FileEntry entry) {
    setState(() => _path = _joinCurrent(entry.name));
    _load();
  }

  void _goUp() {
    if (_path == null) return;
    final dirname = _isRemote ? _remotePath.dirname : p.dirname;
    final parent = dirname(_path!);
    setState(() => _path = parent == _path ? null : parent);
    _load();
  }

  void _goRoot() {
    setState(() => _path = null);
    _load();
  }

  /// 点击：文件夹进入；文件弹出操作菜单。长按：弹出操作菜单。
  void _select(FileEntry entry) {
    if (entry.isDir) {
      _enter(entry);
      return;
    }
    _showEntryActions(entry);
  }

  Future<void> _showEntryActions(FileEntry entry) async {
    final fullPath = _joinCurrent(entry.name);
    final action = await _showActionDialog(context, entry);
    if (!mounted || action == null) return;
    switch (action) {
      case _EntryAction.copy:
        widget.onTransferRequested(entry, fullPath, false);
      case _EntryAction.move:
        widget.onTransferRequested(entry, fullPath, true);
      case _EntryAction.rename:
        await _renameEntry(entry);
      case _EntryAction.edit:
        await _editEntry(entry);
      case _EntryAction.zip:
        await _zipEntry(entry);
      case _EntryAction.unzip:
        await _unzipEntry(entry);
      case _EntryAction.zipMove:
        await _zipAndMove(entry);
      case _EntryAction.unzipMove:
        await _unzipAndMove(entry);
      case _EntryAction.delete:
        await _deleteEntry(entry);
    }
  }

  Future<void> _renameEntry(FileEntry entry) async {
    final from = _joinCurrent(entry.name);
    final name = await _promptText('重命名', '新名称', entry.name);
    if (name == null || name.isEmpty || name == entry.name) return;
    try {
      if (_isRemote) {
        await _clientFor().move(from, _join(_remotePath.dirname(from), name));
      } else {
        await _fs.move(from, p.join(p.dirname(from), name));
      }
      _showMessage('已重命名');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _deleteEntry(FileEntry entry) async {
    final confirmed = await _confirmDelete(entry.name);
    if (!confirmed) return;
    try {
      if (_isRemote) {
        await _clientFor().delete(_joinCurrent(entry.name), recursive: true);
      } else {
        await _fs.delete(_joinCurrent(entry.name), recursive: true);
      }
      _showMessage('已删除 ${entry.name}');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  SyncMateClient _clientFor() {
    final device = widget.device!;
    return _client ??= SyncMateClient(
      baseUrl: device.baseUrl,
      fingerprint: widget.self.fingerprint,
    );
  }

  /// 当前视图目录（根目录时取第一个存储根）。
  String get _currentDir =>
      _path ?? (_entries.isEmpty ? '' : _entries.first.name);

  String _compressBaseName(FileEntry entry) =>
      entry.isDir ? entry.name : p.basenameWithoutExtension(entry.name);

  Future<String> _doCompress(FileEntry entry, String format) {
    final ext = format == 'tar.gz' ? 'tar.gz' : 'zip';
    final archive = _join(_currentDir, '${_compressBaseName(entry)}.$ext');
    final fullPath = _joinCurrent(entry.name);
    if (_isRemote) return _clientFor().compress(fullPath, archive);
    return _fs.compress(fullPath, archive);
  }

  Future<String> _doExtract(FileEntry entry) {
    final fullPath = _joinCurrent(entry.name);
    final container = _isContainerArchive(entry.name);
    final target = container
        ? _join(_currentDir, _archiveBaseName(entry.name))
        : _currentDir;
    if (_isRemote) return _clientFor().extract(fullPath, target);
    return _fs.extract(fullPath, target);
  }

  Future<String?> _pickCompressFormat() {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择压缩格式'),
        children: [
          _FormatOption(
            label: 'zip',
            description: '通用格式，兼容性最好',
            onTap: () => Navigator.of(dialogContext).pop('zip'),
          ),
          _FormatOption(
            label: 'tar.gz',
            description: '压缩率更高，常见于类 Unix 系统',
            onTap: () => Navigator.of(dialogContext).pop('tar.gz'),
          ),
        ],
      ),
    );
  }

  Future<void> _zipEntry(FileEntry entry) async {
    final format = await _pickCompressFormat();
    if (format == null || !mounted) return;
    try {
      final result = await _doCompress(entry, format);
      _showMessage('已压缩为 ${p.basename(result)}');
    } on FsException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('压缩失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _unzipEntry(FileEntry entry) async {
    try {
      final result = await _doExtract(entry);
      _showMessage('已解压到 ${p.basename(result)}');
    } on FsException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('解压失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _zipAndMove(FileEntry entry) async {
    final format = await _pickCompressFormat();
    if (format == null || !mounted) return;
    final String result;
    try {
      result = await _doCompress(entry, format);
    } on FsException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('压缩失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
    widget.onTransferRequested(
      FileEntry(name: p.basename(result), isDir: false, size: 0, modified: 0),
      result,
      true,
    );
  }

  Future<void> _unzipAndMove(FileEntry entry) async {
    final String result;
    try {
      result = await _doExtract(entry);
    } on FsException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('解压失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
    widget.onTransferRequested(
      FileEntry(
        name: p.basename(result),
        isDir: _isContainerArchive(entry.name),
        size: 0,
        modified: 0,
      ),
      result,
      true,
    );
  }

  Future<void> _editEntry(FileEntry entry) async {
    if (entry.size > 512 * 1024) {
      _showMessage('文件超过 512KB，暂不支持编辑');
      return;
    }
    final fullPath = _joinCurrent(entry.name);
    final String initial;
    try {
      initial = _isRemote
          ? await _clientFor().readContent(fullPath)
          : await _fs.readText(fullPath);
    } on FsException catch (e) {
      _showMessage('读取失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('读取失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('读取失败：$e');
      return;
    }
    if (!mounted) return;
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _EditPage(title: entry.name, initial: initial),
      ),
    );
    if (edited == null || !mounted) return;
    try {
      if (_isRemote) {
        await _clientFor().writeContent(fullPath, edited);
      } else {
        await _fs.writeText(fullPath, edited);
      }
      _showMessage('已保存');
    } on FsException catch (e) {
      _showMessage('保存失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('保存失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('保存失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final label = _sourceLabel();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: widget.focused ? AppColors.primary.withValues(alpha: 0.35) : AppColors.border,
          width: widget.focused ? 1.4 : 1,
        ),
        boxShadow: widget.focused ? AppShadows.card : AppShadows.soft,
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: PopupMenuButton<String>(
                    tooltip: '切换视图来源',
                    position: PopupMenuPosition.under,
                    onSelected: (fp) {
                      // PopupMenuItem 的 value 为 null 时点击不会触发 onSelected，
                      // 因此用空串代表本机，选中后再换回 null。
                      final source = fp.isEmpty ? null : fp;
                      if (source != widget.source) widget.onSourceChanged(source);
                    },
                    itemBuilder: (context) => [
                      for (final s in widget.sources)
                        PopupMenuItem<String>(
                          value: s.fingerprint ?? '',
                          child: Text(s.alias),
                        ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: _isRemote
                                ? AppColors.primary.withValues(alpha: 0.10)
                                : AppColors.surfaceSunken,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            _isRemote ? Icons.smartphone_rounded : Icons.computer_rounded,
                            size: 15,
                            color: _isRemote ? AppColors.primary : AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const Icon(Icons.expand_more_rounded,
                            size: 18, color: AppColors.textTertiary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 1, bottom: 4),
              child: Text(
                _path ?? '根目录',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ),
            _buildToolbar(context),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  String _sourceLabel() {
    if (!_isRemote) return '本机';
    final device = widget.device;
    if (device != null) return device.alias;
    return '离线设备';
  }

  Widget _buildToolbar(BuildContext context) {
    return Row(
      children: [
        _ToolbarIconButton(
          tooltip: '返回上级',
          icon: Icons.arrow_upward_rounded,
          onPressed: _path == null ? null : _goUp,
        ),
        const SizedBox(width: 2),
        _ToolbarIconButton(
          tooltip: '根目录',
          icon: Icons.home_rounded,
          onPressed: _path == null ? null : _goRoot,
        ),
        const Spacer(),
        _ToolbarIconButton(
          tooltip: '刷新',
          icon: Icons.refresh_rounded,
          onPressed: _load,
        ),
        const SizedBox(width: 2),
        PopupMenuButton<String>(
          tooltip: '操作',
          position: PopupMenuPosition.under,
          onSelected: (_) => _handleMkdir(),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'mkdir',
              child: Row(
                children: [
                  Icon(Icons.create_new_folder_rounded, size: 18),
                  SizedBox(width: 10),
                  Text('新建文件夹'),
                ],
              ),
            ),
          ],
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surfaceSunken,
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.more_horiz_rounded,
                size: 18, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Future<void> _handleMkdir() async {
    final name = await _promptText('新建文件夹', '文件夹名称', '新建文件夹');
    if (name == null || name.isEmpty) return;
    final base = _path ?? (_entries.isEmpty ? '' : _entries.first.name);
    try {
      if (_isRemote) {
        await _clientFor().mkdir(_join(base, name));
      } else {
        await _fs.mkdir(p.join(base, name));
      }
      _showMessage('已创建 $name');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<String?> _promptText(String title, String label, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
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
  }

  Future<bool> _confirmDelete(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要永久删除「$name」吗？该操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.wifi_off_rounded,
        title: _error!,
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_open_rounded,
        title: '空目录',
        subtitle: '这里还没有文件',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return GestureDetector(
          onLongPress: () => _showEntryActions(entry),
          onSecondaryTap: () => _showEntryActions(entry),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _select(entry),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      _iconFor(entry),
                      size: 20,
                      color: entry.isDir ? AppColors.primary : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          if (!entry.isDir)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                '${formatBytes(entry.size)}  ·  ${_formatTime(entry.modified)}',
                                style: const TextStyle(
                                    fontSize: 10.5, color: AppColors.textTertiary),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 圆角小方块工具栏按钮，禁用态自动变暗。
class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onPressed,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surfaceSunken,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            icon,
            size: 17,
            color: enabled ? AppColors.textSecondary : AppColors.textTertiary.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// 支持的压缩包扩展名（解压可用）。
bool _isArchiveName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.tar.bz2') ||
      lower.endsWith('.tbz2') ||
      lower.endsWith('.tbz') ||
      lower.endsWith('.tar.xz') ||
      lower.endsWith('.txz') ||
      lower.endsWith('.gz') ||
      lower.endsWith('.bz2') ||
      lower.endsWith('.xz');
}

/// 容器型压缩包（解压产出文件夹）；单文件型（.gz/.bz2/.xz）解压产出文件。
bool _isContainerArchive(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.tar.bz2') ||
      lower.endsWith('.tbz2') ||
      lower.endsWith('.tbz') ||
      lower.endsWith('.tar.xz') ||
      lower.endsWith('.txz');
}

/// 去掉压缩包扩展名（含复合扩展名，如 foo.tar.gz → foo）。
String _archiveBaseName(String name) {
  final lower = name.toLowerCase();
  for (final ext in [
    '.tar.gz', '.tar.bz2', '.tar.xz', '.tbz2', '.tbz', '.txz', '.tgz',
    '.zip', '.tar', '.gz', '.bz2', '.xz',
  ]) {
    if (lower.endsWith(ext)) {
      return name.substring(0, name.length - ext.length);
    }
  }
  return name;
}

/// 独立文本编辑页（保存后以内容字符串返回）。
class _EditPage extends StatefulWidget {
  const _EditPage({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<_EditPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              ),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceSunken,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            autofocus: true,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppColors.textPrimary,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              filled: false,
              contentPadding: EdgeInsets.all(14),
              hintText: '文本内容（UTF-8）',
            ),
          ),
        ),
      ),
    );
  }
}

enum _EntryAction {
  copy,
  move,
  rename,
  edit,
  zip,
  unzip,
  zipMove,
  unzipMove,
  delete,
}

Future<_EntryAction?> _showActionDialog(
  BuildContext context,
  FileEntry entry,
) {
  final name = entry.name;
  final isDir = entry.isDir;
  final isArchive = _isArchiveName(name);
  final isContainer = _isContainerArchive(name);
  return showDialog<_EntryAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          Icon(isDir ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
              size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionTile(
              icon: Icons.copy_rounded,
              title: '复制',
              subtitle: '复制到另一视图的当前目录',
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.copy),
            ),
            _ActionTile(
              icon: Icons.drive_file_move_outline,
              title: '移动',
              subtitle: '移动到另一视图的当前目录',
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.move),
            ),
            _ActionTile(
              icon: Icons.drive_file_rename_outline_rounded,
              title: '重命名',
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.rename),
            ),
            if (!isDir)
              _ActionTile(
                icon: Icons.edit_outlined,
                title: '编辑',
                subtitle: '编辑文本内容（UTF-8，≤512KB）',
                onTap: () => Navigator.of(dialogContext).pop(_EntryAction.edit),
              ),
            _ActionTile(
              icon: Icons.folder_zip_rounded,
              title: '压缩',
              subtitle: '打包为 zip / tar.gz',
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.zip),
            ),
            if (isArchive)
              _ActionTile(
                icon: Icons.unarchive_rounded,
                title: '解压',
                subtitle: isContainer ? '解压到同名文件夹' : '解压为同名文件',
                onTap: () => Navigator.of(dialogContext).pop(_EntryAction.unzip),
              ),
            _ActionTile(
              icon: Icons.archive_outlined,
              title: '压缩并移动',
              subtitle: '压缩后移动到另一视图的当前目录',
              onTap: () =>
                  Navigator.of(dialogContext).pop(_EntryAction.zipMove),
            ),
            if (isArchive)
              _ActionTile(
                icon: Icons.unarchive_outlined,
                title: '解压并移动',
                subtitle:
                    isContainer ? '解压后移动到另一视图的当前目录' : '解压为文件后移动到另一视图的当前目录',
                onTap: () =>
                    Navigator.of(dialogContext).pop(_EntryAction.unzipMove),
              ),
            _ActionTile(
              icon: isDir ? Icons.folder_delete_rounded : Icons.delete_outline_rounded,
              title: '删除',
              danger: true,
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.delete),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

/// 操作菜单行：圆角图标块 + 标题 + 可选说明，危险操作用醒目色。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: danger
                      ? AppColors.danger.withValues(alpha: 0.08)
                      : AppColors.surfaceSunken,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: danger ? AppColors.danger : AppColors.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: color)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle!,
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.textTertiary)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _iconFor(FileEntry entry) {
  if (entry.isDir) return Icons.folder_rounded;
  final lower = entry.name.toLowerCase();
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp')) {
    return Icons.image_rounded;
  }
  if (lower.endsWith('.mp4') ||
      lower.endsWith('.mkv') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.webm')) {
    return Icons.movie_rounded;
  }
  if (lower.endsWith('.mp3') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.flac') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.ogg')) {
    return Icons.music_note_rounded;
  }
  if (lower.endsWith('.zip') ||
      lower.endsWith('.rar') ||
      lower.endsWith('.7z') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.gz')) {
    return Icons.folder_zip_rounded;
  }
  return Icons.insert_drive_file_rounded;
}

String _formatTime(int milliseconds) {
  final local = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 压缩格式选择项：标签 + 说明的圆角卡片行。
class _FormatOption extends StatelessWidget {
  const _FormatOption({
    required this.label,
    required this.description,
    required this.onTap,
  });

  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Text(description,
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 18, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
