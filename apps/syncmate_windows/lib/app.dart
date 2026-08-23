import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syncmate_core/syncmate_core.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/home_page.dart';
import 'theme.dart';

class SyncMateWindowsApp extends StatefulWidget {
  const SyncMateWindowsApp({
    super.key,
    required this.server,
    required this.discovery,
    required this.trustStore,
    required this.connections,
    required this.self,
    required this.onExit,
    this.auditLogPath,
  });

  final SyncMateServer server;
  final DiscoveryService discovery;
  final TrustStore trustStore;
  final ConnectionManager connections;
  final DeviceProfile self;
  final String? auditLogPath;

  /// 用户从托盘菜单选择"退出"，或托盘不可用时直接关闭窗口触发：
  /// 停止服务、释放资源、真正退出进程。
  final Future<void> Function() onExit;

  @override
  State<SyncMateWindowsApp> createState() => _SyncMateWindowsAppState();
}

class _SyncMateWindowsAppState extends State<SyncMateWindowsApp>
    with WindowListener, TrayListener {
  static const _keyShow = 'show_window';
  static const _keyExit = 'exit_app';

  /// 托盘初始化失败时置 false：此时没有任何入口能找回被隐藏的窗口，
  /// 关闭按钮改为直接退出，避免应用彻底消失且无法访问。
  bool _trayAvailable = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(_initTray());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('SyncMate');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: _keyShow, label: '显示主窗口'),
        MenuItem.separator(),
        MenuItem(key: _keyExit, label: '退出'),
      ]));
    } on Object catch (e) {
      debugPrint('SyncMate: 托盘初始化失败，关闭窗口将直接退出: $e');
      if (mounted) setState(() => _trayAvailable = false);
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    await trayManager.destroy();
    await widget.onExit();
  }

  // ---------------------------------------------------------------------
  // WindowListener
  // ---------------------------------------------------------------------

  @override
  void onWindowClose() async {
    if (_trayAvailable) {
      await windowManager.hide();
    } else {
      await _exitApp();
    }
  }

  // ---------------------------------------------------------------------
  // TrayListener
  // ---------------------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == _keyShow) {
      unawaited(_showWindow());
    } else if (menuItem.key == _keyExit) {
      unawaited(_exitApp());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncMate',
      debugShowCheckedModeBanner: false,
      theme: buildSyncMateTheme(),
      home: HomePage(
        server: widget.server,
        discovery: widget.discovery,
        trustStore: widget.trustStore,
        connections: widget.connections,
        self: widget.self,
        auditLogPath: widget.auditLogPath,
      ),
    );
  }
}
