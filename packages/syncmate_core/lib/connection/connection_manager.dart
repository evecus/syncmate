/// 设备长连接管理器：每个已信任设备维护一条独立的 WS 长连接状态。
///
/// 语义（与短连接的 HTTP 请求/剪切板 WS 完全独立）：
/// - App 启动后，对发现在线的已信任设备自动尝试连接；
/// - 用户可随时手动断开：断开后在本次 App 生命周期内不再自动重连，
///   直到用户手动再次点击连接，或 App 重启；
/// - 非手动断线（网络抖动、对方退出等）会按退避策略自动重连；
/// - 文件浏览/传输等业务操作要求先处于 [ConnectionStatus.connected]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import '../discovery/discovery_service.dart';
import '../model/device_profile.dart';
import '../security/trust_store.dart';
import '../server/syncmate_server.dart';

enum ConnectionStatus { disconnected, connecting, connected }

class DeviceConnectionState {
  const DeviceConnectionState({
    required this.fingerprint,
    required this.status,
    this.manuallyDisconnected = false,
  });

  final String fingerprint;
  final ConnectionStatus status;

  /// 用户主动断开后置位；置位期间不参与自动重连/自动首连。
  final bool manuallyDisconnected;

  DeviceConnectionState copyWith({
    ConnectionStatus? status,
    bool? manuallyDisconnected,
  }) {
    return DeviceConnectionState(
      fingerprint: fingerprint,
      status: status ?? this.status,
      manuallyDisconnected: manuallyDisconnected ?? this.manuallyDisconnected,
    );
  }
}

class _Session {
  _Session(this.fingerprint);

  final String fingerprint;
  ConnectionStatus status = ConnectionStatus.disconnected;
  bool manuallyDisconnected = false;
  WebSocket? ws;
  int backoffSeconds = 1;

  /// 本次 connect() 调用序号；用于丢弃过期异步回调（例如断开后旧连接才建立成功）。
  int generation = 0;
  DateTime lastRx = DateTime.now();
  Timer? reconnectTimer;
}

class ConnectionManager {
  ConnectionManager({
    required DeviceProfile self,
    required TrustStore trustStore,
    required DiscoveryService discovery,
    Stream<ConnectionServerEvent>? serverEvents,
  })  : _self = self,
        _trustStore = trustStore,
        _discovery = discovery {
    _discoverySub = discovery.events.listen(_onDiscoveryEvent);
    _serverSub = serverEvents?.listen(_onServerEvent);
  }

  final DeviceProfile _self;
  final TrustStore _trustStore;
  final DiscoveryService _discovery;
  final Map<String, _Session> _sessions = {};
  final StreamController<void> _state = StreamController<void>.broadcast();
  late final StreamSubscription<DiscoveryEvent> _discoverySub;
  StreamSubscription<ConnectionServerEvent>? _serverSub;
  Timer? _pingTimer;
  bool _started = false;

  /// 状态变化通知（任意设备的连接状态发生变化时触发）。
  Stream<void> get state => _state.stream;

  ConnectionStatus statusOf(String fingerprint) =>
      _sessions[fingerprint]?.status ?? ConnectionStatus.disconnected;

  bool isConnected(String fingerprint) =>
      statusOf(fingerprint) == ConnectionStatus.connected;

  List<String> get connectedFingerprints => [
        for (final s in _sessions.values)
          if (s.status == ConnectionStatus.connected) s.fingerprint,
      ];

  /// 启动：开始心跳巡检 + 对在线已信任设备发起自动首连。
  void start() {
    if (_started) return;
    _started = true;
    _pingTimer = Timer.periodic(
      Constants.connectionHeartbeatInterval,
      (_) => _pingAll(),
    );
    unawaited(_autoConnectOnlineTrusted());
  }

  Future<void> dispose() async {
    _pingTimer?.cancel();
    await _discoverySub.cancel();
    await _serverSub?.cancel();
    for (final session in _sessions.values) {
      _teardown(session);
    }
    _sessions.clear();
    await _state.close();
  }

  /// 手动发起连接（用户点击"连接"，或自动首连）。
  Future<void> connect(String fingerprint) async {
    final trusted = await _trustStore.find(fingerprint);
    if (trusted == null) return;
    final device = _onlineDevice(fingerprint);
    if (device == null) return; // 对方不在线，无法建立长连接
    final session = _sessions.putIfAbsent(
      fingerprint,
      () => _Session(fingerprint),
    );
    session.manuallyDisconnected = false;
    if (session.status == ConnectionStatus.connected ||
        session.status == ConnectionStatus.connecting) {
      return;
    }
    session.backoffSeconds = 1;
    await _doConnect(session, device.baseUrl);
  }

  /// 手动断开（用户点击"断开连接"）。断开后不再自动重连，直到用户
  /// 重新调用 [connect] 或 App 重启。
  Future<void> disconnect(String fingerprint) async {
    final session = _sessions[fingerprint];
    if (session == null) return;
    session.manuallyDisconnected = true;
    session.generation++; // 使任何在途的连接尝试失效
    session.reconnectTimer?.cancel();
    final ws = session.ws;
    session.ws = null;
    session.status = ConnectionStatus.disconnected;
    _state.add(null);
    if (ws != null) {
      try {
        await ws.close();
      } on Object {
        // ignore
      }
    }
  }

  DiscoveredDevice? _onlineDevice(String fingerprint) {
    for (final device in _discovery.devices) {
      if (device.fingerprint == fingerprint) return device;
    }
    return null;
  }

  Future<void> _autoConnectOnlineTrusted() async {
    final trusted = await _trustStore.load();
    for (final device in trusted) {
      final online = _onlineDevice(device.fingerprint);
      if (online == null) continue;
      unawaited(connect(device.fingerprint));
    }
  }

  Future<void> _onDiscoveryEvent(DiscoveryEvent event) async {
    if (event is DeviceExpired) {
      // 对方离线：视为断线（非手动），保留 manuallyDisconnected 标记，
      // 允许后续设备重新上线时按标记决定是否自动重连。
      final session = _sessions[event.device.fingerprint];
      if (session != null) {
        _onSocketDone(session, auto: !session.manuallyDisconnected);
      }
      return;
    }
    final device = switch (event) {
      DeviceDiscovered(:final device) => device,
      DeviceUpdated(:final device) => device,
      DeviceExpired() => throw StateError('unreachable'),
    };
    if (device.fingerprint == _self.fingerprint || !_started) return;
    final trusted = await _trustStore.find(device.fingerprint);
    if (trusted == null) return;
    final session = _sessions[device.fingerprint];
    if (session != null && session.manuallyDisconnected) return;
    if (session != null && session.status != ConnectionStatus.disconnected) {
      return;
    }
    // 新上线或重新上线的已信任设备：自动尝试连接（除非用户此前手动断开）。
    unawaited(connect(device.fingerprint));
  }

  void _onServerEvent(ConnectionServerEvent event) {
    // 入站连接事件目前仅用于潜在的 UI 展示（例如“对方也主动连了我”），
    // 不驱动本机的 connected 状态——状态以本机主动发起的出站连接为准，
    // 保证“连接/断开”按钮语义单一、可预期。
  }

  Future<void> _doConnect(_Session session, String baseUrl) async {
    final generation = ++session.generation;
    session.status = ConnectionStatus.connecting;
    _state.add(null);
    try {
      final wsUri = Uri.parse(baseUrl)
          .replace(scheme: 'ws', path: Constants.connectionWsPath);
      final ws = await WebSocket.connect(
        wsUri.toString(),
        headers: {_headerFingerprint: _self.fingerprint},
      ).timeout(Constants.connectTimeout);
      if (generation != session.generation) {
        // 连接期间被手动断开或又发起了新一轮连接，丢弃这个过期结果。
        await ws.close();
        return;
      }
      session.ws = ws;
      session.status = ConnectionStatus.connected;
      session.backoffSeconds = 1;
      session.lastRx = DateTime.now();
      _state.add(null);
      ws.listen(
        (data) => _onSocketData(session, generation, data),
        onDone: () {
          if (generation == session.generation) _onSocketDone(session);
        },
        onError: (Object _) {
          if (generation == session.generation) _onSocketDone(session);
        },
      );
    } on Object {
      if (generation == session.generation) _onSocketDone(session);
    }
  }

  void _onSocketData(_Session session, int generation, dynamic data) {
    if (generation != session.generation) return;
    session.lastRx = DateTime.now();
    if (data is! String) return;
    if (data == '{"type":"ping"}') {
      try {
        session.ws?.add('{"type":"pong"}');
      } on Object {
        // ignore
      }
    }
  }

  /// 连接断开（非手动）：进入 disconnected，按退避策略安排重连；
  /// 手动断开的场景由 [disconnect] 直接处理，不经过这里的重连调度。
  void _onSocketDone(_Session session, {bool auto = true}) {
    session.ws = null;
    session.status = ConnectionStatus.disconnected;
    _state.add(null);
    if (!_started || session.manuallyDisconnected || !auto) return;
    final delay = Duration(seconds: session.backoffSeconds);
    final maxBackoff = Constants.connectionReconnectMax.inSeconds;
    session.backoffSeconds =
        session.backoffSeconds * 2 > maxBackoff ? maxBackoff : session.backoffSeconds * 2;
    session.reconnectTimer?.cancel();
    session.reconnectTimer = Timer(delay, () {
      if (session.manuallyDisconnected) return;
      final device = _onlineDevice(session.fingerprint);
      if (device == null) return; // 仍离线，等下一次发现事件触发
      unawaited(_doConnect(session, device.baseUrl));
    });
  }

  void _pingAll() {
    final now = DateTime.now();
    for (final session in _sessions.values) {
      final ws = session.ws;
      if (ws == null || session.status != ConnectionStatus.connected) continue;
      try {
        ws.add('{"type":"ping"}');
      } on Object {
        // ignore
      }
      if (now.difference(session.lastRx) > Constants.connectionHeartbeatTimeout) {
        unawaited(ws.close());
      }
    }
  }

  void _teardown(_Session session) {
    session.manuallyDisconnected = true;
    session.generation++;
    session.reconnectTimer?.cancel();
    session.ws?.close();
    session.ws = null;
  }
}

const _headerFingerprint = 'X-SyncMate-Fingerprint';
