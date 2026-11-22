import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'config_service.dart';

/// 按功能区分代理策略的网络类别。
enum NetworkFeature { novelAi, agent, gallery, other }

/// 全局 HTTP 代理。
///
/// - 生图、Agent/LLM、图源三大类通过 [createClient] 拿到显式客户端，
///   可分别选择走代理或直连；
/// - 未显式注入的请求仍受 [HttpOverrides.global] 影响 (代理开启时)；
/// - 已建立的客户端不会热切换，保存设置后建议重启应用。
class NetworkProxyService {
  NetworkProxyService._();

  static final NetworkProxyService instance = NetworkProxyService._();

  bool _enabled = false;
  String _host = '';
  int _port = 7890;
  bool _useNovelAi = true;
  bool _useAgent = true;
  bool _useGallery = true;
  String? _appliedSignature;
  HttpOverrides? _previousOverrides;
  bool _installed = false;

  bool get enabled => _enabled;
  String get host => _host;
  int get port => _port;
  bool get useNovelAi => _useNovelAi;
  bool get useAgent => _useAgent;
  bool get useGallery => _useGallery;

  /// 代理 authority，例如 `127.0.0.1:7890`；IPv6 自动加方括号。
  String get authority {
    if (!_host.contains(':')) return '$_host:$_port';
    final bracketed = _host.startsWith('[') && _host.endsWith(']')
        ? _host
        : '[$_host]';
    return '$bracketed:$_port';
  }

  void configure({
    required bool enabled,
    required String host,
    required int port,
    bool useNovelAi = true,
    bool useAgent = true,
    bool useGallery = true,
  }) {
    final normalizedHost = host.trim();
    final valid = enabled && isValidHost(normalizedHost) && isValidPort(port);
    final nextEnabled = valid;
    final nextHost = valid ? normalizedHost : '';
    final nextPort = valid ? port : 7890;
    final signature =
        '$nextEnabled|$nextHost|$nextPort|$useNovelAi|$useAgent|$useGallery';
    if (_appliedSignature == signature) return;
    _appliedSignature = signature;
    _enabled = nextEnabled;
    _host = nextHost;
    _port = nextPort;
    _useNovelAi = useNovelAi;
    _useAgent = useAgent;
    _useGallery = useGallery;
    if (nextEnabled) {
      // 保留宿主原有的 HttpOverrides，关闭代理时恢复。
      if (!_installed) {
        _previousOverrides = HttpOverrides.current;
        _installed = true;
      }
      HttpOverrides.global = _ProxyHttpOverrides(authority);
    } else if (_installed) {
      HttpOverrides.global = _previousOverrides;
      _previousOverrides = null;
      _installed = false;
    }
  }

  void configureFromConfig(AppConfig config) {
    configure(
      enabled: config.proxyEnabled,
      host: config.proxyHost,
      port: config.proxyPort,
      useNovelAi: config.proxyUseNovelAi,
      useAgent: config.proxyUseAgent,
      useGallery: config.proxyUseGallery,
    );
  }

  /// 该功能当前是否会走代理（供测试与诊断；实际请求由客户端创建时决定）。
  bool usesProxy(NetworkFeature feature) => _enabled && _usesProxy(feature);

  /// 为单个功能创建动态客户端：每次发起请求时读取最新代理设置，
  /// 因此在功能界面切换开关后，下一条请求立即生效。
  http.Client createClient(NetworkFeature feature) =>
      _FeatureProxyClient(this, feature);

  /// 动态客户端当前配置签名；设置变化时用来自动重建底层 HttpClient。
  String clientSignature(NetworkFeature feature) =>
      '$_enabled|$_host|$_port|${_usesProxy(feature)}';

  HttpClient _buildFeatureClient(
    NetworkFeature feature, {
    bool forceDirect = false,
  }) {
    final client = HttpClient();
    final useProxy = !forceDirect && _enabled && _usesProxy(feature);
    client.findProxy = (uri) => _directive(uri, useProxy: useProxy);
    return client;
  }

  DateTime? _proxyProbeAt;
  bool _proxyProbeOk = false;

  /// 代理端口不可达时（例如代理软件未启动或端口已变）快速失败并改走直连，
  /// 避免生图请求等到系统级连接拒绝/超时才报错。
  Future<bool> proxyReachable() async {
    if (!_enabled) return false;
    final now = DateTime.now();
    if (_proxyProbeAt != null &&
        now.difference(_proxyProbeAt!) < const Duration(seconds: 5)) {
      return _proxyProbeOk;
    }
    _proxyProbeAt = now;
    try {
      final socket = await Socket.connect(
        _host,
        _port,
        timeout: const Duration(milliseconds: 600),
      );
      socket.destroy();
      _proxyProbeOk = true;
    } on Object {
      _proxyProbeOk = false;
    }
    return _proxyProbeOk;
  }

  /// 强制直连客户端 (ComfyUI 等本机/局域网服务)。
  http.Client createDirectClient() {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    return IOClient(client);
  }

  bool _usesProxy(NetworkFeature feature) => switch (feature) {
    NetworkFeature.novelAi => _useNovelAi,
    NetworkFeature.agent => _useAgent,
    NetworkFeature.gallery => _useGallery,
    NetworkFeature.other => true,
  };

  /// 返回该 URI 的代理指令；localhost/本机/内网地址直连。
  String proxyDirectiveFor(Uri uri) => _directive(uri, useProxy: _enabled);

  String _directive(Uri uri, {required bool useProxy}) {
    if (!useProxy) return 'DIRECT';
    if (_isDirectHost(uri.host)) return 'DIRECT';
    if (uri.scheme != 'http' && uri.scheme != 'https') return 'DIRECT';
    return 'PROXY $authority';
  }

  /// 诊断用：按给定 host/port 请求一次 NovelAI 端点。
  static Future<String> probeNovelAi({
    required String host,
    required int port,
  }) async {
    final trimmed = host.trim();
    if (!isValidHost(trimmed) || !isValidPort(port)) {
      return '代理地址或端口无效';
    }
    final authority = trimmed.contains(':') ? '[$trimmed]:$port' : '$trimmed:$port';
    final client = HttpClient();
    client.findProxy = (_) => 'PROXY $authority';
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(
        Uri.parse('https://image.novelai.net/'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      await response.drain<void>();
      return 'HTTP ${response.statusCode}';
    } on Object catch (error) {
      return '失败：$error';
    } finally {
      client.close(force: true);
    }
  }

  static bool isValidHost(String value) {
    final host = value.trim();
    if (host.isEmpty || host.length > 253) return false;
    if (host.contains('://') ||
        host.contains('/') ||
        host.contains('\\') ||
        host.contains(' ')) {
      return false;
    }
    return true;
  }

  static bool isValidPort(int port) => port >= 1 && port <= 65535;

  static bool _isDirectHost(String hostName) {
    final host = hostName.toLowerCase();
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      if (bytes[0] == 10) return true;
      if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
      if (bytes[0] == 192 && bytes[1] == 168) return true;
      return false;
    }
    // IPv6 unique-local fc00::/7 与 link-local fe80::/10
    if ((bytes[0] & 0xFE) == 0xFC) return true;
    return bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80;
  }
}

class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this.authority);

  final String authority;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (NetworkProxyService._isDirectHost(uri.host) ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        return 'DIRECT';
      }
      return 'PROXY $authority';
    };
    return client;
  }
}

/// 每次请求检查代理配置签名；变化时关闭旧底层客户端并重建。
class _FeatureProxyClient extends http.BaseClient {
  _FeatureProxyClient(this._service, this._feature);

  final NetworkProxyService _service;
  final NetworkFeature _feature;
  http.Client? _delegate;
  http.Client? _directDelegate;
  String? _signature;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final signature = _service.clientSignature(_feature);
    if (_delegate == null || signature != _signature) {
      _delegate?.close();
      _delegate = IOClient(_service._buildFeatureClient(_feature));
      _signature = signature;
    }
    // 代理端口拒绝连接时不要直接把错误抛给用户：先探测一次，决定是否直连。
    if (_service.usesProxy(_feature) && !await _service.proxyReachable()) {
      _directDelegate ??= IOClient(
        _service._buildFeatureClient(_feature, forceDirect: true),
      );
      return _directDelegate!.send(request);
    }
    return _delegate!.send(request);
  }

  @override
  void close() {
    _delegate?.close();
    _delegate = null;
    _directDelegate?.close();
    _directDelegate = null;
  }
}
