import 'package:flutter/material.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'pages/home_page.dart';
import 'theme.dart';

class SyncMateAndroidApp extends StatelessWidget {
  const SyncMateAndroidApp({
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
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncMate',
      debugShowCheckedModeBanner: false,
      theme: buildSyncMateTheme(),
      home: HomePage(
        server: server,
        discovery: discovery,
        trustStore: trustStore,
        connections: connections,
        self: self,
        auditLogPath: auditLogPath,
      ),
    );
  }
}
