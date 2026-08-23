import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncmate_core/syncmate_core.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'platform/prefs_key_value_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final kv = SharedPreferencesKeyValueStore(prefs);
  final identity = KeyValueIdentityProvider(kv);
  final trustStore = KeyValueTrustStore(kv);
  final profile = DeviceProfile(
    alias: '我的电脑',
    deviceType: 'windows',
    fingerprint: await identity.identity,
    port: Constants.httpPort,
    protocol: Constants.protocol,
    appVersion: Constants.appVersion,
  );
  final server = SyncMateServer(
    self: profile,
    trustStore: trustStore,
    auditLogPath: _resolveAuditLogPath(),
  );
  final discovery = DiscoveryService(profileProvider: () async => profile);
  await server.start();
  await discovery.start();

  final connections = ConnectionManager(
    self: profile,
    trustStore: trustStore,
    discovery: discovery,
    serverEvents: server.connectionEvents,
  );
  connections.start();

  // 关闭按钮不直接销毁窗口，改由 WindowListener（app.dart）拦截并隐藏到托盘。
  await windowManager.setPreventClose(true);

  runApp(SyncMateWindowsApp(
    server: server,
    discovery: discovery,
    trustStore: trustStore,
    connections: connections,
    self: profile,
    auditLogPath: server.auditLogPath,
    onExit: () async {
      await connections.dispose();
      await discovery.stop();
      await server.stop();
      exit(0);
    },
  ));
}

/// 操作留痕路径：%APPDATA%\\SyncMate\\audit.log；不可写则返回 null（留痕关闭）。
String? _resolveAuditLogPath() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return null;
  final path = '$appData\\SyncMate\\audit.log';
  try {
    File(path).createSync(recursive: true);
    return path;
  } on Object {
    return null;
  }
}
