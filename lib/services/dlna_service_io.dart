import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cast_log.dart';

/// DLNA/UPnP 回调集合：由播放器注入实际控制能力
class DlnaHooks {
  final void Function(String url, String title) onPlay;
  final void Function() onPause;
  final void Function() onResume;
  final void Function() onStop;
  final void Function(Duration position) onSeek;
  final void Function(double volume) onSetVolume;
  final void Function(bool muted) onSetMute;
  final String Function() transportState;
  final Duration Function() position;
  final Duration Function() duration;
  final double Function() volume;
  final bool Function() muted;

  const DlnaHooks({
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onSeek,
    required this.onSetVolume,
    required this.onSetMute,
    required this.transportState,
    required this.position,
    required this.duration,
    required this.volume,
    required this.muted,
  });
}

/// DLNA/UPnP MediaRenderer 服务（接收手机等设备投屏）
///
/// 实现：SSDP 组播发现（1900/UDP）+ HTTP 设备描述/SCPD + SOAP 控制端点。
/// 支持 AVTransport（SetAVTransportURI/Play/Pause/Stop/Seek）与
/// RenderingControl（音量），Stop 时由播放器恢复投屏前状态。
class DlnaService {
  HttpServer? _http;
  RawDatagramSocket? _ssdp;
  Timer? _aliveTimer;
  String _uuid = '';
  String _name = '';
  int _port = 0;
  String _ip = '127.0.0.1';

  /// 启动时缓存的本机网卡列表（供按对端子网选择 LOCATION IP 使用）
  List<NetworkInterface> _ifaces = [];
  DlnaHooks? _hooks;
  String? _currentUri;
  String _currentTitle = '';

  /// GENA 事件订阅：key = 事件路径（/event/AVTransport 等）
  final Map<String, _EventSubscription> _subs = {};
  static const _subLifetime = Duration(seconds: 300);

  /// 播放中定时把进度/状态推给订阅者（发送端可实时显示播放进度）
  Timer? _positionEventTimer;
  String? _lastPushedState;
  int _lastPushedPosSec = -1;

  /// 高频轮询动作的诊断日志限频（最多 10 秒一条）
  final Map<String, DateTime> _lastPollLog = {};

  /// 起播确认监视：SetAVTransportURI/Play 后短时间内高频检查状态，
  /// 一旦对外状态变成 PLAYING 立即推送事件。
  /// 抖音极速版等发送端在 SetURI 后只等约 2~3 秒，收不到 PLAYING
  /// 就判定“投屏失败”（即使稍后实际已播放），并禁用清晰度切换等功能。
  Timer? _readyWatchTimer;
  String? _readyWatchLastState;
  static const _noisyActions = {
    'GetPositionInfo',
    'GetTransportInfo',
    'GetVolume',
    'GetMute',
    'GetMediaInfo',
  };

  bool get isRunning => _http != null && _ssdp != null;

  /// 清空当前投屏媒体：投屏结束（Stop/自动恢复）后调用，
  /// 这样发送端轮询 GetMediaInfo/GetPositionInfo 时看到无媒体，
  /// 即使 GENA 通知因跨网段发不出去，发送端也能知道投屏已结束
  /// （否则发送端会一直显示"已连接"，点断开也无反应）。
  /// 同时立即向订阅者推一条 STOPPED 事件——这是接收端主动断开时
  /// 通知投送端的关键：不推的话它那边还显示"投屏中"。
  void clearCurrentMedia() {
    final wasActive = _currentUri != null && _currentUri!.isNotEmpty;
    _currentUri = null;
    _currentTitle = '';
    _lastPushedPosSec = -1;
    if (wasActive) {
      final sub = _subs['/event/AVTransport'];
      if (sub != null) {
        _lastPushedState = 'STOPPED';
        _notify(sub, _avtEventBody());
        return;
      }
    }
    _lastPushedState = null;
  }

  /// 设备名称（OMPlayer + 机器标识）
  String get deviceName => _name;

  /// HTTP 服务地址（http://ip:port），用于排查连通性
  String get deviceEndpoint => 'http://$_ip:$_port';

  /// 启动服务；任何失败静默返回，不阻塞播放器
  Future<void> start({required String uuid, required DlnaHooks hooks}) async {
    if (_http != null || _ssdp != null) return;
    _uuid = uuid;
    _hooks = hooks;
    try {
      _name = _resolveName();
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _http = server;
      _port = server.port;
      server.listen(_handleRequest, onError: (_) {});
    } catch (_) {
      _http = null;
      return;
    }
    try {
      _ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      _ip = await _localIp();
      await _startSsdp();
    } catch (_) {}

    // 播放中每 2 秒向订阅者推送一次播放状态/进度，
    // 发送端（手机）就能实时显示播放位置、播放/暂停状态。
    // 状态变化时立即推；位置整秒变化时推送，避免无意义风暴。
    _positionEventTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _pushTick());
  }

  void _pushTick() {
    final sub = _subs['/event/AVTransport'];
    if (sub == null || _hooks == null) return;
    final state = _exposedState;
    final posSec = _hooks!.position().inSeconds;
    if (state != _lastPushedState) {
      _lastPushedState = state;
      _lastPushedPosSec = posSec;
      _notify(sub, _avtEventBody());
    } else if (state == 'PLAYING' && posSec != _lastPushedPosSec) {
      _lastPushedPosSec = posSec;
      _notify(sub, _avtEventBody());
    }
  }

  /// 对外（投送端/控制点）暴露的传输状态。
  /// 无投屏媒体时一律 STOPPED：投屏断开后本地会恢复之前的频道，
  /// 但那是本机的事，不能把本地的 PLAYING 报给投送端，
  /// 否则它一直认为投屏还在进行、UI 停在"投屏中"。
  String get _exposedState {
    final uri = _currentUri;
    if (uri == null || uri.isEmpty) return 'STOPPED';
    return _hooks?.transportState() ?? 'STOPPED';
  }

  void stop() {
    _aliveTimer?.cancel();
    _positionEventTimer?.cancel();
    _readyWatchTimer?.cancel();
    for (final s in _subs.values) {
      s.expireTimer.cancel();
    }
    _subs.clear();
    _ssdp?.close();
    _http?.close();
    _aliveTimer = null;
    _positionEventTimer = null;
    _readyWatchTimer = null;
    _ssdp = null;
    _http = null;
  }

  /// 启动起播确认监视：每 200ms 检查一次，状态变化即推送，
  /// 见到 PLAYING 后停止；最长 9 秒。
  void _startReadyWatch() {
    _readyWatchTimer?.cancel();
    _readyWatchLastState = _exposedState;
    var ticks = 0;
    _readyWatchTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      ticks++;
      final sub = _subs['/event/AVTransport'];
      final state = _exposedState;
      if (sub != null && state != _readyWatchLastState) {
        _readyWatchLastState = state;
        _lastPushedState = state;
        _notify(sub, _avtEventBody());
      }
      if (state == 'PLAYING' || ticks >= 45) {
        t.cancel();
        _readyWatchTimer = null;
      }
    });
  }

  // ==================== 设备名称 ====================

  String _resolveName() {
    String host = '';
    try {
      host = Platform.localHostname;
    } catch (_) {}
    final lower = host.toLowerCase();
    if (host.isNotEmpty &&
        lower != 'localhost' &&
        !lower.startsWith('android-') &&
        RegExp(r'^[a-zA-Z0-9\-_]+$').hasMatch(host)) {
      return 'OMPlayer-$host';
    }
    // hostname 不可靠（如安卓模拟器）时用 uuid 前缀
    final suffix = _uuid.length >= 6 ? _uuid.substring(0, 6) : _uuid;
    return 'OMPlayer-${suffix.toUpperCase()}';
  }

  /// 选择最可能被手机访问到的本机 IP：
  /// 优先 192.168.* 真实网卡，其次 10.* / 172.16-31.*，
  /// 跳过链路本地地址并降低虚拟网卡（VMware/Hyper-V/WSL 等）优先级
  Future<String> _localIp() async {
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      String best = '';
      var bestScore = -1;
      for (final i in ifs) {
        final name = i.name.toLowerCase();
        final isVirtual = name.contains('virtual') ||
            name.contains('vmware') ||
            name.contains('hyper-v') ||
            name.contains('vethernet') ||
            name.contains('wsl') ||
            name.contains('docker') ||
            name.contains('vbox') ||
            name.contains('loopback');
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          final addr = a.address;
          int score;
          if (addr.startsWith('169.254.')) {
            continue; // 链路本地不可用
          } else if (addr.startsWith('192.168.')) {
            score = isVirtual ? 40 : 100;
          } else if (addr.startsWith('10.')) {
            score = isVirtual ? 30 : 80;
          } else if (addr.startsWith('172.')) {
            final second = int.tryParse(addr.split('.')[1]) ?? 0;
            if (second >= 16 && second <= 31) {
              score = isVirtual ? 20 : 60;
            } else {
              continue;
            }
          } else {
            score = 5; // 其它地址保底
          }
          if (score > bestScore) {
            bestScore = score;
            best = addr;
          }
        }
      }
      if (best.isNotEmpty) return best;
    } catch (_) {}
    return '127.0.0.1';
  }

  // ==================== SSDP 发现 ====================

  Future<void> _startSsdp() async {
    final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 1900,
        reuseAddress: true);
    // 在所有非回环网卡上加入组播组（虚拟网卡多的机器上，
    // 只加默认网卡会导致手机扫描不到）
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifs) {
        try {
          socket.joinMulticast(InternetAddress('239.255.255.250'), i);
        } catch (_) {}
      }
    } catch (_) {
      try {
        socket.joinMulticast(InternetAddress('239.255.255.250'));
      } catch (_) {}
    }
    _ssdp = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final msg = String.fromCharCodes(dg.data);
      if (!msg.toUpperCase().contains('M-SEARCH')) return;
      final st = _headerValue(msg, 'ST');
      if (st == null || st.isEmpty) return;
      _respondSearch(dg.address, dg.port, st);
    });
    // 启动时主动通告存在，提高被投屏端发现的概率
    for (var i = 0; i < 3; i++) {
      _notifyAlive();
      await Future.delayed(const Duration(milliseconds: 400));
    }
    _aliveTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _notifyAlive());
  }

  String? _headerValue(String msg, String field) {
    for (final line in msg.split('\r\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toUpperCase() ==
          field.toUpperCase()) {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }

  void _respondSearch(InternetAddress addr, int port, String st) {
    final socket = _ssdp;
    if (socket == null) return;
    // 热点/多网卡环境：请求来自哪张网卡的子网，LOCATION 就用哪张网卡的本机 IP，
    // 否则手机拿到的地址可能选到另一张网卡（如同时连路由器和手机热点），
    // 导致设备描述/SOAP 请求不可达而投屏失败
    final location = 'http://${_ipForPeer(addr.address)}:$_port/device.xml';
    final usnBase = 'uuid:$_uuid';
    void send(String stVal, String usn) {
      final resp = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'EXT:\r\n'
          'LOCATION: $location\r\n'
          'SERVER: OMPlayer/1.0 UPnP/1.0\r\n'
          'BOOTID.UPNP.ORG: 1\r\n'
          'CONFIGID.UPNP.ORG: 1\r\n'
          'ST: $stVal\r\n'
          'USN: $usn\r\n\r\n';
      socket.send(resp.codeUnits, addr, port);
    }

    // 略微延迟回复，避免同网络设备风暴
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_ssdp == null) return;
      if (st == 'ssdp:all') {
        send('upnp:rootdevice', '$usnBase::upnp:rootdevice');
        send(usnBase, usnBase);
        send('urn:schemas-upnp-org:device:MediaRenderer:1',
            '$usnBase::urn:schemas-upnp-org:device:MediaRenderer:1');
      } else if (st == 'upnp:rootdevice') {
        send(st, '$usnBase::upnp:rootdevice');
      } else if (st == usnBase) {
        send(st, usnBase);
      } else if (st.contains('MediaRenderer') ||
          st.contains('MediaServer') ||
          st.contains('AVTransport')) {
        send(st, '$usnBase::$st');
      }
    });
  }

  void _notifyAlive() {
    final socket = _ssdp;
    if (socket == null) return;
    final usnBase = 'uuid:$_uuid';
    final entries = <List<String>>[
      ['upnp:rootdevice', '$usnBase::upnp:rootdevice'],
      [usnBase, usnBase],
      [
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        '$usnBase::urn:schemas-upnp-org:device:MediaRenderer:1'
      ],
    ];
    for (final e in entries) {
      final pkt = 'NOTIFY * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: ${_location}\r\n'
          'NT: ${e[0]}\r\n'
          'NTS: ssdp:alive\r\n'
          'SERVER: OMPlayer/1.0 UPnP/1.0\r\n'
          'BOOTID.UPNP.ORG: 1\r\n'
          'CONFIGID.UPNP.ORG: 1\r\n'
          'USN: ${e[1]}\r\n\r\n';
      socket.send(pkt.codeUnits, InternetAddress('239.255.255.250'), 1900);
    }
  }

  String get _location => 'http://$_ip:$_port/device.xml';

  /// 选择与对端 [peer] 同网段的本机 IPv4（同 /24 优先，其次同 /16），
  /// 找不到再退回全局最优 IP（_ip）。网卡列表用启动时缓存的 _ifaces
  String _ipForPeer(String peer) {
    final pp = peer.split('.');
    if (pp.length != 4) return _ip;
    String same16 = '';
    for (final i in _ifaces) {
      for (final a in i.addresses) {
        if (a.isLoopback) continue;
        final ap = a.address.split('.');
        if (ap.length != 4) continue;
        if (ap[0] == pp[0] && ap[1] == pp[1] && ap[2] == pp[2]) {
          return a.address; // 同 /24：最优
        }
        if (ap[0] == pp[0] && ap[1] == pp[1] && same16.isEmpty) {
          same16 = a.address;
        }
      }
    }
    if (same16.isNotEmpty) return same16;
    return _ip;
  }

  // ==================== HTTP 服务 ====================

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      // 记录每一个 HTTP 请求：定位非标准发送端（如抖音极速版）实际发出的
      // 完整请求序列（订阅/轮询/探测），而不只是 SOAP
      CastLog.write(
          'HTTP ${req.method} $path from=${req.connectionInfo?.remoteAddress.address}');
      if (req.method == 'GET' || req.method == 'HEAD') {
        if (path == '/device.xml') {
          await _respondXml(req, _deviceXml());
        } else if (path == '/icon.png') {
          await _respondBytes(req, _iconPng, 'image/png');
        } else if (path == '/scpd/AVTransport.xml') {
          await _respondXml(req, _scpdAvTransport);
        } else if (path == '/scpd/RenderingControl.xml') {
          await _respondXml(req, _scpdRenderingControl);
        } else if (path == '/scpd/ConnectionManager.xml') {
          await _respondXml(req, _scpdConnectionManager);
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
        return;
      }
      if (req.method == 'SUBSCRIBE' || req.method == 'UNSUBSCRIBE') {
        await _handleGenSub(req, path);
        return;
      }
      if (req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        await _handleSoap(req, body);
        return;
      }
      req.response.statusCode = 405;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  // ==================== GENA 事件订阅 ====================

  String _sidFor(String path) {
    if (path.contains('AVTransport')) return 'uuid:$_uuid-avt';
    if (path.contains('RenderingControl')) return 'uuid:$_uuid-rc';
    return 'uuid:$_uuid-cm';
  }

  Future<void> _handleGenSub(HttpRequest req, String path) async {
    final h = req.headers;
    final sidHdr = h.value('SID');
    if (req.method == 'UNSUBSCRIBE') {
      final sub = _findSubBySid(sidHdr ?? '');
      if (sub != null) {
        sub.expireTimer.cancel();
        _subs.removeWhere((_, s) => s.sid == sub.sid);
      }
      CastLog.write('GENA unsubscribe sid=$sidHdr found=${sub != null}');
      req.response.statusCode = 200;
      req.response.contentLength = 0;
      await req.response.close();
      return;
    }

    // 续订：带 SID，无 CALLBACK
    if (sidHdr != null && sidHdr.isNotEmpty) {
      final sub = _findSubBySid(sidHdr);
      if (sub == null) {
        CastLog.write('GENA renew unknown sid=$sidHdr -> 412');
        req.response.statusCode = 412;
        await req.response.close();
        return;
      }
      _armExpiry(sub, path);
      CastLog.write('GENA renew sid=$sidHdr path=$path');
      req.response.headers.set('SID', sub.sid);
      req.response.headers.set('TIMEOUT', 'Second-${_subLifetime.inSeconds}');
      req.response.statusCode = 200;
      req.response.contentLength = 0;
      await req.response.close();
      return;
    }

    // 新订阅：CALLBACK: <url>；NT: upnp:event
    final cbRaw = h.value('CALLBACK') ?? '';
    final m = RegExp(r'<([^>]+)>').firstMatch(cbRaw);
    if (m == null) {
      CastLog.write('GENA subscribe without CALLBACK -> 412 (path=$path)');
      req.response.statusCode = 412;
      await req.response.close();
      return;
    }
    final callback = m.group(1)!;
    final sid = _sidFor(path);
    final peerHost =
        h.value('X-Forwarded-For') ?? req.connectionInfo?.remoteAddress.address ?? '';
    _subs[path]?.expireTimer.cancel();
    final sub = _EventSubscription(
        sid: sid, callback: callback, peerHost: peerHost);
    _subs[path] = sub;
    _armExpiry(sub, path);
    CastLog.write(
        'GENA subscribe path=$path sid=$sid callback=$callback from=$peerHost');

    req.response.headers.set('SID', sid);
    req.response.headers.set('TIMEOUT', 'Second-${_subLifetime.inSeconds}');
    req.response.headers.set('SERVER', 'OMPlayer/1.0 UPnP/1.0');
    req.response.statusCode = 200;
    req.response.contentLength = 0;
    await req.response.close();

    // UPnP 要求订阅成功后立即推送一次「全量事件」。
    // 抖音等 App 等待该通知确认连接，收不到会在约 10 秒后提示重试。
    Timer(const Duration(milliseconds: 200), () {
      _sendInitialEvent(path);
    });
  }

  void _armExpiry(_EventSubscription sub, String path) {
    sub.expireTimer.cancel();
    sub.expireTimer = Timer(_subLifetime, () {
      if (_subs[path]?.sid == sub.sid) _subs.remove(path);
    });
  }

  _EventSubscription? _findSubBySid(String sid) {
    for (final s in _subs.values) {
      if (s.sid == sid) return s;
    }
    return null;
  }

  /// 订阅后首条全量事件
  void _sendInitialEvent(String path) {
    final sub = _subs[path];
    if (sub == null) return;
    if (path.contains('AVTransport')) {
      _notify(sub, _avtEventBody());
    } else if (path.contains('RenderingControl')) {
      _notify(sub, _rcEventBody());
    } else {
      const sink = 'http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,'
          'http-get:*:video/avi:*,http-get:*:video/mpeg:*,'
          'http-get:*:video/mp2t:*,http-get:*:application/vnd.apple.mpegurl:*,'
          'http-get:*:application/x-mpegURL:*,http-get:*:video/*:*,'
          'http-get:*:audio/*:*,http-get:*:image/*:*';
      _notify(
          sub,
          '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">'
          '<e:property><SourceProtocolInfo></SourceProtocolInfo></e:property>'
          '<e:property><SinkProtocolInfo>$sink</SinkProtocolInfo></e:property>'
          '<e:property><CurrentConnectionIDs></CurrentConnectionIDs>'
          '</e:property></e:propertyset>');
    }
  }

  /// AVTransport 状态变化事件（播放/暂停/停止/切地址后调用）
  void _fireAvtChange() {
    _lastPushedState = null;
    final sub = _subs['/event/AVTransport'];
    if (sub != null) _notify(sub, _avtEventBody());
  }

  /// RenderingControl 状态变化事件（音量/静音改变后调用）
  void _fireRcChange() {
    final sub = _subs['/event/RenderingControl'];
    if (sub != null) _notify(sub, _rcEventBody());
  }

  String _avtEventBody() {
    final hooks = _hooks;
    final hasMedia = _currentUri != null && _currentUri!.isNotEmpty;
    final state = _exposedState;
    final pos = hooks == null ? '0:00:00' : _fmtTime(hooks.position());
    final dur = hooks == null ? '0:00:00' : _fmtTime(hooks.duration());
    final uri = _xmlEscape(_currentUri ?? '');
    // 无媒体时 CurrentTrack=0（DLNA 规范：Track 0 表示无加载的媒体）
    final track = hasMedia ? '1' : '0';
    final inner = '<InstanceID val="0">'
        '<TransportState val="$state"/>'
        '<TransportStatus val="OK"/>'
        '<CurrentTrack val="$track"/>'
        '<AVTransportURI val="$uri"/>'
        '<AVTransportURIMetaData val=""/>'
        '<CurrentTrackURI val="$uri"/>'
        '<CurrentTrackMetaData val=""/>'
        '<CurrentTrackDuration val="$dur"/>'
        '<RelativeTimePosition val="$pos"/>'
        '<AbsoluteTimePosition val="$pos"/>'
        '</InstanceID>';
    final lastChange = _xmlEscape(
        '<Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">$inner</Event>');
    return '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">'
        '<e:property><LastChange>$lastChange</LastChange></e:property>'
        '</e:propertyset>';
  }

  String _rcEventBody() {
    final hooks = _hooks;
    final vol = ((hooks?.volume() ?? 0.8) * 100).round().clamp(0, 100);
    final mute = (hooks?.muted() ?? false) ? '1' : '0';
    final inner = '<InstanceID val="0">'
        '<Volume channel="Master" val="$vol"/>'
        '<Mute channel="Master" val="$mute"/>'
        '</InstanceID>';
    final lastChange = _xmlEscape(
        '<Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/">$inner</Event>');
    // 两种标准形式都带上：
    // - LastChange（BubbleUPnP 等通用控制点使用）
    // - 直接 Volume/Mute 属性（部分发送端只解析独立属性）
    return '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">'
        '<e:property><LastChange>$lastChange</LastChange></e:property>'
        '<e:property><Volume channel="Master">$vol</Volume></e:property>'
        '<e:property><Mute channel="Master">$mute</Mute></e:property>'
        '</e:propertyset>';
  }

  /// 向控制点回调地址发送 GENA NOTIFY（失败静默，不影响播放）。
  /// 每个订阅串行排队，保证 SEQ 严格递增、不被网络延迟乱序，
  /// 否则严格的发送端收到 SEQ 回退会丢弃事件并提示重试。
  Future<void> _notify(_EventSubscription sub, String body) async {
    final seq = sub.seq++;
    final data = utf8.encode(body);
    final prev = sub.sending;
    final completer = Completer<void>();
    sub.sending = completer.future;
    // 等上一条发完（或失败）再发本条
    prev.whenComplete(() => completer.complete());
    await prev;
    // 回调地址不可达（如多网卡/企业 WiFi 隔离）退避期间丢弃事件
    final cd = sub.cooldownUntil;
    if (cd != null && DateTime.now().isBefore(cd)) return;

    Future<int> sendTo(Uri uri) async {
      HttpClient? client;
      try {
        client = HttpClient();
        // openUrl 内部建连，黑洞地址会挂 21 秒才抛 errno 121，强制 3 秒超时
        final request = await client
            .openUrl('NOTIFY', uri)
            .timeout(const Duration(seconds: 3));
        request.headers
            .set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
        request.headers.set('NT', 'upnp:event');
        request.headers.set('NTS', 'upnp:propchange');
        request.headers.set('SID', sub.sid);
        request.headers.set('SEQ', '$seq');
        request.contentLength = data.length;
        request.add(data);
        final resp = await request.close().timeout(const Duration(seconds: 3));
        final sc = resp.statusCode;
        resp.drain<void>();
        return sc;
      } finally {
        client?.close(force: true);
      }
    }

    try {
      final uri = Uri.parse(sub.callback);
      int sc;
      try {
        sc = await sendTo(uri);
      } catch (e) {
        // CALLBACK 地址不可达（多网卡时手机给的地址可能不在可达网段）：
        // 用订阅来源 IP 替换 host 兜底一次
        if (sub.peerHost.isNotEmpty && sub.peerHost != uri.host) {
          final alt = uri.replace(host: sub.peerHost);
          CastLog.write(
              'GENA callback ${uri.host} unreachable, retry via ${sub.peerHost}');
          sc = await sendTo(alt);
          // 记住可达地址，后续事件直接用
          sub.callback = alt.toString();
        } else {
          rethrow;
        }
      }
      // 发送成功：清除退避
      sub.failStreak = 0;
      sub.cooldownUntil = null;
      // 412 Precondition Failed：SID 无效，控制点要求重新订阅
      if (sc == 412) {
        CastLog.write('GENA NOTIFY 412, drop sid=${sub.sid}');
        _subs.removeWhere((_, s) => s.sid == sub.sid);
      }
    } catch (e) {
      // 指数退避：4s、8s、16s、30s、30s…
      const waits = [4, 8, 16, 30];
      sub.failStreak++;
      final waitSec = waits[(sub.failStreak - 1).clamp(0, waits.length - 1)];
      sub.cooldownUntil =
          DateTime.now().add(Duration(seconds: waitSec));
      CastLog.write(
          'GENA NOTIFY failed seq=$seq streak=${sub.failStreak} '
          'backoff=${waitSec}s -> $e');
    }
  }

  // ==================== SOAP 控制 ====================

  Future<void> _handleSoap(HttpRequest req, String body) async {
    final hooks = _hooks;
    if (hooks == null) {
      req.response.statusCode = 503;
      await req.response.close();
      return;
    }
    final soapAction = (req.headers.value('SOAPACTION') ?? '')
        .replaceAll('"', '')
        .trim();
    final hashIdx = soapAction.indexOf('#');
    final service = hashIdx >= 0 ? soapAction.substring(0, hashIdx) : '';
    final action =
        hashIdx >= 0 ? soapAction.substring(hashIdx + 1).trim() : '';

    _logSoap(service, action, body,
        req.connectionInfo?.remoteAddress.address ?? '?');

    if (service.contains('AVTransport')) {
      switch (action) {
        case 'SetAVTransportURI':
          _currentUri = _extract(body, 'CurrentURI');
          _currentTitle = _extractCastTitle(body);
          // 新地址：重置进度推送缓存
          _lastPushedState = null;
          _lastPushedPosSec = -1;
          if (_currentUri != null && _currentUri!.isNotEmpty) {
            hooks.onPlay(_currentUri!, _currentTitle);
          }
          await _soapResponse(req, service, action, '');
          // 立即推送一次状态事件：抖音等发送端等待首条事件确认连接
          _fireAvtChange();
          // 高频监视起播：状态一变成 PLAYING 立即推送（初始化通常需
          // 2~3 秒），让发送端在超时窗口内确认投屏成功、启用清晰度选择
          _startReadyWatch();
          return;
        case 'Play':
          hooks.onResume();
          await _soapResponse(req, service, action, '');
          _startReadyWatch();
          return;
        case 'Pause':
          hooks.onPause();
          await _soapResponse(req, service, action, '');
          _fireAvtChange();
          return;
        case 'Stop':
          // 发送端主动停止：立即清空当前媒体，让 GetMediaInfo 返回空，
          // 发送端轮询即可知道投屏已结束（不依赖 GENA 通知）
          _currentUri = null;
          _currentTitle = '';
          hooks.onStop();
          await _soapResponse(req, service, action, '');
          _fireAvtChange();
          return;
        case 'Seek':
          final target = _extract(body, 'Target');
          final d = _parseTime(target);
          if (d != null) hooks.onSeek(d);
          await _soapResponse(req, service, action, '');
          _fireAvtChange();
          return;
        case 'GetTransportInfo':
          await _soapResponse(req, service, action,
              '<CurrentTransportState>$_exposedState</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>'
              '<CurrentSpeed>1</CurrentSpeed>');
          return;
        case 'GetPositionInfo':
          final hasMedia =
              _currentUri != null && _currentUri!.isNotEmpty;
          final uri = _xmlEscape(_currentUri ?? '');
          if (!hasMedia) {
            // 无媒体：Track=0、URI/时长/位置全空，投送端据此结束投屏 UI
            await _soapResponse(req, service, action,
                '<Track>0</Track>'
                '<TrackDuration></TrackDuration>'
                '<TrackMetaData></TrackMetaData>'
                '<TrackURI></TrackURI>'
                '<RelTime></RelTime>'
                '<AbsTime></AbsTime>'
                '<RelCount>2147483647</RelCount>'
                '<AbsCount>2147483647</AbsCount>');
            return;
          }
          final pos = _fmtTime(hooks.position());
          // 直播流/时长未知时按规范返回空串，不能返回 0:00:00，
          // 否则部分发送端会把进度算成 100% 或判定异常
          final dur = hooks.duration() > Duration.zero
              ? _fmtTime(hooks.duration())
              : '';
          await _soapResponse(req, service, action,
              '<Track>1</Track>'
              '<TrackDuration>$dur</TrackDuration>'
              '<TrackMetaData></TrackMetaData>'
              '<TrackURI>$uri</TrackURI>'
              '<RelTime>$pos</RelTime>'
              '<AbsTime>$pos</AbsTime>'
              '<RelCount>2147483647</RelCount>'
              '<AbsCount>2147483647</AbsCount>');
          return;
        case 'GetMediaInfo':
          final uri = _xmlEscape(_currentUri ?? '');
          final hasMedia =
              _currentUri != null && _currentUri!.isNotEmpty;
          if (!hasMedia) {
            await _soapResponse(req, service, action,
                '<NrTracks>0</NrTracks>'
                '<MediaDuration></MediaDuration>'
                '<CurrentURI></CurrentURI>'
                '<CurrentURIMetaData></CurrentURIMetaData>'
                '<NextURI></NextURI>'
                '<NextURIMetaData></NextURIMetaData>'
                '<PlayMedium>NONE</PlayMedium>'
                '<RecordMedium>NOT_IMPLEMENTED</RecordMedium>'
                '<WriteStatus>NOT_IMPLEMENTED</WriteStatus>');
            return;
          }
          final dur = hooks.duration() > Duration.zero
              ? _fmtTime(hooks.duration())
              : '';
          await _soapResponse(req, service, action,
              '<NrTracks>1</NrTracks>'
              '<MediaDuration>$dur</MediaDuration>'
              '<CurrentURI>$uri</CurrentURI>'
              '<CurrentURIMetaData></CurrentURIMetaData>'
              '<NextURI></NextURI>'
              '<NextURIMetaData></NextURIMetaData>'
              '<PlayMedium>NETWORK</PlayMedium>'
              '<RecordMedium>NOT_IMPLEMENTED</RecordMedium>'
              '<WriteStatus>NOT_IMPLEMENTED</WriteStatus>');
          return;
        case 'GetCurrentTransportActions':
          // 无媒体时只报 Play；有媒体时直播流不可 Seek；点播支持完整操作
          if (_currentUri == null || _currentUri!.isEmpty) {
            await _soapResponse(req, service, action,
                '<Actions>Play</Actions>');
            return;
          }
          final canSeek = hooks.duration() > Duration.zero;
          final actions = canSeek
              ? 'Play,Pause,Stop,Seek,X_DLNA_SeekTime'
              : 'Play,Pause,Stop';
          await _soapResponse(req, service, action,
              '<Actions>$actions</Actions>');
          return;
        case 'Next':
        case 'Previous':
        case 'SetPlayMode':
        case 'SetNextAVTransportURI':
          // 单轨渲染器：接受请求但不做实际动作
          await _soapResponse(req, service, action, '');
          return;
        default:
          await _soapResponse(req, service, action, '');
          return;
      }
    }

    if (service.contains('RenderingControl')) {
      switch (action) {
        case 'SetVolume': {
          final v = int.tryParse(_extract(body, 'DesiredVolume')) ?? -1;
          if (v >= 0 && v <= 100) {
            hooks.onSetVolume(v / 100.0);
            // 音量从 0 调起时自动解除静音（标准渲染器行为）
            if (v > 0 && hooks.muted()) hooks.onSetMute(false);
            _fireRcChange();
          }
          await _soapResponse(req, service, action, '');
          return;
        }
        case 'GetVolume': {
          // 主通道或全通道（部分发送端传空串）都返回当前音量
          final vol = (hooks.volume().clamp(0.0, 1.0) * 100).round();
          await _soapResponse(req, service, action,
              '<CurrentVolume>$vol</CurrentVolume>');
          return;
        }
        case 'SetMute': {
          final raw = _extract(body, 'DesiredMute').toLowerCase();
          final mute = raw == '1' || raw == 'true';
          hooks.onSetMute(mute);
          _fireRcChange();
          await _soapResponse(req, service, action, '');
          return;
        }
        case 'GetMute': {
          final m = hooks.muted() ? '1' : '0';
          await _soapResponse(req, service, action, '<CurrentMute>$m</CurrentMute>');
          return;
        }
        default:
          await _soapResponse(req, service, action, '');
          return;
      }
    }

    if (service.contains('ConnectionManager')) {
      switch (action) {
        case 'GetProtocolInfo':
          // 我们是接收端（Sink），Source 留空；Sink 声明支持的协议，
          // 抖音会据此判断能否投屏，必须非空且包含 mp4
          await _soapResponse(req, service, action,
              '<Source></Source>'
              '<Sink>http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,http-get:*:video/avi:*,http-get:*:video/mpeg:*,http-get:*:video/mp2t:*,http-get:*:application/vnd.apple.mpegurl:*,http-get:*:application/x-mpegURL:*,http-get:*:video/*:*,http-get:*:audio/*:*,http-get:*:image/*:*</Sink>');
          return;
        case 'GetCurrentConnectionIDs':
          await _soapResponse(req, service, action,
              '<ConnectionIDs>0</ConnectionIDs>');
          return;
        case 'GetCurrentConnectionInfo':
          // 部分发送端（微信等）建链时会查询连接信息，缺失会导致其放弃投屏。
          // 返回一个处于 Input/OK 状态的连接（RcsID/AVTransportID=0）。
          await _soapResponse(req, service, action,
              '<RcsID>0</RcsID>'
              '<AVTransportID>0</AVTransportID>'
              '<ProtocolInfo></ProtocolInfo>'
              '<PeerConnectionManager></PeerConnectionManager>'
              '<PeerConnectionID>-1</PeerConnectionID>'
              '<Direction>Input</Direction>'
              '<Status>OK</Status>');
          return;
        default:
          await _soapResponse(req, service, action, '');
          return;
      }
    }

    req.response.statusCode = 404;
    CastLog.write('SOAP unhandled: $service#$action -> 404');
    await req.response.close();
  }

  /// SOAP 信令诊断日志：控制类动作全量记录，高频轮询 10 秒限频一条
  void _logSoap(String service, String action, String body, String fromIp) {
    final shortSvc = service.contains('AVTransport')
        ? 'AVT'
        : service.contains('RenderingControl')
            ? 'RCS'
            : service.contains('ConnectionManager')
                ? 'CM'
                : service;
    if (_noisyActions.contains(action)) {
      final last = _lastPollLog[action];
      if (last != null &&
          DateTime.now().difference(last) < const Duration(seconds: 10)) {
        return;
      }
      _lastPollLog[action] = DateTime.now();
    }
    String extra = '';
    switch (action) {
      case 'SetAVTransportURI':
        extra = ' uri=${_extract(body, 'CurrentURI')}';
        break;
      case 'Seek':
        extra = ' unit=${_extract(body, 'Unit')} '
            'target=${_extract(body, 'Target')}';
        break;
      case 'SetVolume':
        extra = ' vol=${_extract(body, 'DesiredVolume')}';
        break;
      case 'SetMute':
        extra = ' mute=${_extract(body, 'DesiredMute')}';
        break;
      case 'Play':
        extra = ' speed=${_extract(body, 'Speed')}';
        break;
    }
    CastLog.write('SOAP[$shortSvc] $action$extra from=$fromIp');
  }

  // ==================== XML/SOAP 工具 ====================

  String _extract(String body, String tag) {
    final m = RegExp('<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>',
            caseSensitive: false)
        .firstMatch(body);
    return m == null ? '' : _xmlUnescape(m.group(1)!.trim());
  }

  String _extractCastTitle(String body) {
    final meta = _extract(body, 'CurrentURIMetaData');
    if (meta.isEmpty) return '';
    final m =
        RegExp('<dc:title>([\\s\\S]*?)</dc:title>', caseSensitive: false)
            .firstMatch(meta);
    if (m == null) return '';
    final t = _xmlUnescape(m.group(1)!.trim());
    // dc:title 内容本身可能仍带 CDATA/转义，去掉 CDATA 包裹
    return t.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').trim();
  }

  Duration? _parseTime(String s) {
    final str = s.trim();
    final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})$').firstMatch(str);
    if (m != null) {
      final h = int.tryParse(m.group(1) ?? '0') ?? 0;
      final min = int.tryParse(m.group(2) ?? '') ?? 0;
      final sec = int.tryParse(m.group(3) ?? '') ?? 0;
      return Duration(hours: h, minutes: min, seconds: sec);
    }
    final sec = int.tryParse(str);
    if (sec != null) return Duration(seconds: sec);
    return null;
  }

  String _fmtTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _xmlUnescape(String s) {
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  String _xmlEscape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  Future<void> _soapResponse(
      HttpRequest req, String service, String action, String argsXml) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$service">$argsXml</u:$action></s:Body>'
        '</s:Envelope>';
    await _respondXml(req, body);
  }

  Future<void> _respondXml(HttpRequest req, String xml) async {
    final data = utf8.encode(xml);
    req.response.headers
        .set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
    // UPnP 设备惯例：所有 HTTP 响应带 SERVER 头
    req.response.headers.set('SERVER', 'OMPlayer/1.0 UPnP/1.0');
    req.response.contentLength = data.length;
    req.response.add(data);
    await req.response.close();
  }

  Future<void> _respondBytes(
      HttpRequest req, List<int> data, String mime) async {
    req.response.headers.set(HttpHeaders.contentTypeHeader, mime);
    req.response.headers.set('SERVER', 'OMPlayer/1.0 UPnP/1.0');
    req.response.contentLength = data.length;
    req.response.add(data);
    await req.response.close();
  }

  // ==================== 描述文件 ====================

  /// device.xml 中 iconList 引用的 48x48 图标
  static final List<int> _iconPng = base64Decode(_iconPngB64);
  static const String _iconPngB64 =
      'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAQNSURBVGhD7ZjfS1RBFMf7OyzNMrUfumlpbRlaEbURJGGBUIktvYhZYigG/YCCkOjB6sGHihDBQiTqRSmQIHwRoQgfCoIFH3oqgnwSejjt93pnPc6eO3fu3ZVLcAc+sHvvzJn5zpw5c+ZuKClJ0P9MLCBqYgFREwuImlhA1BRVwKbyJqpuHqDa0yPUcGmG9nfN52i8POs833HsHm2uTontw1CwAAx6V+oBHbj2jQ7fJWua+n/Q7rNjBYsJLQADT5x5Ts03l8QBBmHP+TehhYQSUJnsokODP8XBYCUgrKqplyoa0muAC8GVpHYtd5Zp+5FbYn8mAgvA4PTOMWh0jlWR2khAIPaGbmtvxzRtLG0U20gEEgCf5Z3BfbAaUl1bttZdoIN9mTV2sUpSXQlrAVh+3knyyhcq23ZUrBsUrBz2AbeP/1JdHSsBmCVl+ONX8i1TUzM0N/fJ/UdUV5cvdHz8tft29b3ungi5ejsdXwHwRx4iP3z+7XbrXSCgp+eG+4+c37pdVSCUP+crARf1W2VfAYjxyiAiBTeYSrW7wyDnN55V1ayEQ8yqKpht1UZvp4vDhPE94edKvgK4MYjh7yQBJ9Mj1PUkQ8kTvc5KqFJZmcy1Gxp67D6V3QshV/WJSTNFN6MA7vtYTj28eQkYnCCHR5Pf3bdEbW3pXLtMZtF5prsPB0FC9W06H4wC+KaSltJPwO3VfUrPXkw677lrSXtDwV3XFFaNApCQKSM4ePT3fgLAfMatkC2t3WPUN3Df/bfWrXTKd7bm+kbeJNUBRgE8+sCd9Pc2AkZn3QrZ8nCaaGHxr/P75au3efY4cFfVN5DqAKMAnu9IyZaNAO5G7xbcH9ny9P0fqmk8l2eT49c/MArgEQhLqr+3EQC4G6myr+Vinj0d1Tfwyo+MAnjmKOU8tgK4G6Ho54IEzhvVN1ZCqgOMAurbJ3JGkAvp720FDIz+cmutlM7Oq3m2dHCzU30jpEp1gFEAIo8yYooEHC7g+ugSHe8YptIy+/RYwSOgNHkKowD4Hb9x2aTOENA/vuyEzPIK+/sBB+6DE1j1a7qtGQUAfgfApvbaTIr65nQuHwoLn32T+wBfAZgNvgo4naV6xYL7PpDOH46vAIC8nBu1ydPDgCSOuw6CiFSPYyUA6JfxYovATPOVRtCwuWNbC4Ax/dsPErwgF3kv9JsYBm/7mcVaAMB+gHHeGQ4ZhLmgQhAMkHHq9rAKW2rNKQYnkACAgfJrHwefSWpODXvOHiYArocoI31XgpuijtTWi8ACFDgT9NmTQBjkG1MCYsLuqdACFF4fqGzABGDgfmeLiYIFKLD0uPrhy5q+2fmA4SbwfSm7DUPRBHiB2F7IDPux7gLWm1hA1MQCoiYWEC0J+gfTHkI1puDBvgAAAABJRU5ErkJggg==';

  static const String _scpdAvTransport =
      '''<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<actionList>
<action>
<name>SetAVTransportURI</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
<argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>Play</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>Pause</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>Stop</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>Seek</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Unit</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekMode</relatedStateVariable></argument>
<argument><name>Target</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekTarget</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetTransportInfo</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
<argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
<argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetPositionInfo</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Track</name><direction>out</direction><relatedStateVariable>CurrentTrack</relatedStateVariable></argument>
<argument><name>TrackDuration</name><direction>out</direction><relatedStateVariable>CurrentTrackDuration</relatedStateVariable></argument>
<argument><name>TrackMetaData</name><direction>out</direction><relatedStateVariable>CurrentTrackMetaData</relatedStateVariable></argument>
<argument><name>TrackURI</name><direction>out</direction><relatedStateVariable>CurrentTrackURI</relatedStateVariable></argument>
<argument><name>RelTime</name><direction>out</direction><relatedStateVariable>RelativeTimePosition</relatedStateVariable></argument>
<argument><name>AbsTime</name><direction>out</direction><relatedStateVariable>AbsoluteTimePosition</relatedStateVariable></argument>
<argument><name>RelCount</name><direction>out</direction><relatedStateVariable>RelativeCounterPosition</relatedStateVariable></argument>
<argument><name>AbsCount</name><direction>out</direction><relatedStateVariable>AbsoluteCounterPosition</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetMediaInfo</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>NrTracks</name><direction>out</direction><relatedStateVariable>NumberOfTracks</relatedStateVariable></argument>
<argument><name>MediaDuration</name><direction>out</direction><relatedStateVariable>CurrentMediaDuration</relatedStateVariable></argument>
<argument><name>CurrentURI</name><direction>out</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
<argument><name>CurrentURIMetaData</name><direction>out</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
<argument><name>NextURI</name><direction>out</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
<argument><name>NextURIMetaData</name><direction>out</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
<argument><name>PlayMedium</name><direction>out</direction><relatedStateVariable>PlaybackStorageMedium</relatedStateVariable></argument>
<argument><name>RecordMedium</name><direction>out</direction><relatedStateVariable>RecordStorageMedium</relatedStateVariable></argument>
<argument><name>WriteStatus</name><direction>out</direction><relatedStateVariable>RecordMediumWriteStatus</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetCurrentTransportActions</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Actions</name><direction>out</direction><relatedStateVariable>CurrentTransportActions</relatedStateVariable></argument>
</argumentList>
</action>
</actionList>
<serviceStateTable>
<stateVariable sendEvents="no"><name>TransportState</name><dataType>string</dataType><allowedValueList><allowedValue>STOPPED</allowedValue><allowedValue>PLAYING</allowedValue><allowedValue>PAUSED_PLAYBACK</allowedValue><allowedValue>TRANSITIONING</allowedValue><allowedValue>NO_MEDIA_PRESENT</allowedValue></allowedValueList></stateVariable>
<stateVariable sendEvents="no"><name>TransportStatus</name><dataType>string</dataType><allowedValueList><allowedValue>OK</allowedValue><allowedValue>ERROR_OCCURRED</allowedValue></allowedValueList></stateVariable>
<stateVariable sendEvents="no"><name>TransportPlaySpeed</name><dataType>string</dataType><allowedValueList><allowedValue>1</allowedValue></allowedValueList></stateVariable>
<stateVariable sendEvents="no"><name>PlaybackStorageMedium</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>RecordStorageMedium</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>RecordMediumWriteStatus</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>NumberOfTracks</name><dataType>ui4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentMediaDuration</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>NextAVTransportURI</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>NextAVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTransportActions</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType><allowedValueList><allowedValue>REL_TIME</allowedValue><allowedValue>TRACK_NR</allowedValue></allowedValueList></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
</serviceStateTable>
</scpd>''';

  static const String _scpdRenderingControl =
      '''<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<actionList>
<action>
<name>SetVolume</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>DesiredVolume</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Volume</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetVolume</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>CurrentVolume</name><direction>out</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetMute</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>CurrentMute</name><direction>out</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>SetMute</name>
<argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>DesiredMute</name><direction>in</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
</argumentList>
</action>
</actionList>
<serviceStateTable>
<stateVariable sendEvents="yes"><name>Volume</name><dataType>ui2</dataType><allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange></stateVariable>
<stateVariable sendEvents="yes"><name>Mute</name><dataType>boolean</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_Channel</name><dataType>string</dataType><allowedValueList><allowedValue>Master</allowedValue></allowedValueList></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_Volume</name><dataType>ui2</dataType><allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange></stateVariable>
</serviceStateTable>
</scpd>''';

  static const String _scpdConnectionManager =
      '''<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<actionList>
<action>
<name>GetProtocolInfo</name>
<argumentList>
<argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
<argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
</argumentList>
</action>
<action>
<name>GetCurrentConnectionIDs</name>
<argumentList>
<argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument>
</argumentList>
</action>
</actionList>
<serviceStateTable>
<stateVariable sendEvents="yes"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="yes"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="yes"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType><allowedValueList><allowedValue>Input</allowedValue><allowedValue>Output</allowedValue></allowedValueList></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType><allowedValueList><allowedValue>OK</allowedValue><allowedValue>ContentFormatMismatch</allowedValue><allowedValue>InsufficientBandwidth</allowedValue><allowedValue>UnreliableChannel</allowedValue><allowedValue>Unknown</allowedValue></allowedValueList></stateVariable>
</serviceStateTable>
</scpd>''';

  String _deviceXml() => '<?xml version="1.0" encoding="utf-8"?>'
      '<root xmlns="urn:schemas-upnp-org:device-1-0" '
      'xmlns:dlna="urn:schemas-dlna-org:device-1-0">'
      '<specVersion><major>1</major><minor>0</minor></specVersion>'
      '<device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>${_xmlEscape(_name)}</friendlyName>'
      '<manufacturer>OMPlayer</manufacturer>'
      '<modelDescription>OMPlayer DLNA Renderer</modelDescription>'
      '<modelName>OMPlayer</modelName>'
      '<modelNumber>1.0</modelNumber>'
      '<UDN>uuid:$_uuid</UDN>'
      // DLNA 互操作声明：标识为完整的 DMR-1.50 数字媒体渲染器。
      // 抖音/乐播等国产投屏 SDK 据此启用清晰度选择等完整控制能力，
      // 缺失时仅按基础 UPnP 设备降级投屏
      '<dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>'
      '<dlna:X_DLNACAP/>'
      '<iconList>'
      '<icon><mimetype>image/png</mimetype><width>48</width><height>48</height>'
      '<depth>32</depth><url>/icon.png</url></icon>'
      '</iconList>'
      '<serviceList>'
      '<service>'
      '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
      '<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>'
      '<SCPDURL>/scpd/AVTransport.xml</SCPDURL>'
      '<controlURL>/control/AVTransport</controlURL>'
      '<eventSubURL>/event/AVTransport</eventSubURL>'
      '</service>'
      '<service>'
      '<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>'
      '<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>'
      '<SCPDURL>/scpd/RenderingControl.xml</SCPDURL>'
      '<controlURL>/control/RenderingControl</controlURL>'
      '<eventSubURL>/event/RenderingControl</eventSubURL>'
      '</service>'
      '<service>'
      '<serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>'
      '<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>'
      '<SCPDURL>/scpd/ConnectionManager.xml</SCPDURL>'
      '<controlURL>/control/ConnectionManager</controlURL>'
      '<eventSubURL>/event/ConnectionManager</eventSubURL>'
      '</service>'
      '</serviceList>'
      '</device>'
      '</root>';
}

/// 一个 GENA 事件订阅（控制点回调）
class _EventSubscription {
  final String sid;
  String callback;
  int seq = 0;
  Timer expireTimer;

  /// 订阅请求的来源 IP（多网卡时 CALLBACK 里的地址可能不可达，
  /// 用它作为兜底 host）
  String peerHost;

  /// 串行发送队列：保证事件按入队顺序送达
  Future<void> sending = Future.value();

  /// 回调地址连续失败退避（企业 WiFi 隔离时地址不可达）
  int failStreak = 0;
  DateTime? cooldownUntil;

  _EventSubscription({
    required this.sid,
    required this.callback,
    required this.peerHost,
  }) : expireTimer = Timer(Duration.zero, () {});
}
