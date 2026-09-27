import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// DLNA/UPnP 回调集合：由播放器注入实际控制能力
class DlnaHooks {
  final void Function(String url, String title) onPlay;
  final void Function() onPause;
  final void Function() onResume;
  final void Function() onStop;
  final void Function(Duration position) onSeek;
  final void Function(double volume) onSetVolume;
  final String Function() transportState;
  final Duration Function() position;
  final Duration Function() duration;
  final double Function() volume;

  const DlnaHooks({
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onSeek,
    required this.onSetVolume,
    required this.transportState,
    required this.position,
    required this.duration,
    required this.volume,
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
  DlnaHooks? _hooks;
  String? _currentUri;
  String _currentTitle = '';

  bool get isRunning => _http != null && _ssdp != null;

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
      _ip = await _localIp();
      await _startSsdp();
    } catch (_) {}
  }

  void stop() {
    _aliveTimer?.cancel();
    _ssdp?.close();
    _http?.close();
    _aliveTimer = null;
    _ssdp = null;
    _http = null;
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
    final location = _location;
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

  // ==================== HTTP 服务 ====================

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' || req.method == 'HEAD') {
        if (path == '/device.xml') {
          await _respondXml(req, _deviceXml());
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
        // 不实现 GENA 事件推送，仅返回合法头（多数投屏端靠轮询即可工作）
        req.response.headers.set('SID', 'uuid:$_uuid-sub');
        req.response.headers.set('TIMEOUT', 'Second-1800');
        req.response.statusCode = 200;
        req.response.contentLength = 0;
        await req.response.close();
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

    if (service.contains('AVTransport')) {
      switch (action) {
        case 'SetAVTransportURI':
          _currentUri = _extract(body, 'CurrentURI');
          _currentTitle = _extractCastTitle(body);
          if (_currentUri != null && _currentUri!.isNotEmpty) {
            hooks.onPlay(_currentUri!, _currentTitle);
          }
          await _soapResponse(req, service, action, '');
          return;
        case 'Play':
          hooks.onResume();
          await _soapResponse(req, service, action, '');
          return;
        case 'Pause':
          hooks.onPause();
          await _soapResponse(req, service, action, '');
          return;
        case 'Stop':
          hooks.onStop();
          await _soapResponse(req, service, action, '');
          return;
        case 'Seek':
          final target = _extract(body, 'Target');
          final d = _parseTime(target);
          if (d != null) hooks.onSeek(d);
          await _soapResponse(req, service, action, '');
          return;
        case 'GetTransportInfo':
          await _soapResponse(req, service, action,
              '<CurrentTransportState>${hooks.transportState()}</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>'
              '<CurrentSpeed>1</CurrentSpeed>');
          return;
        case 'GetPositionInfo':
          final pos = _fmtTime(hooks.position());
          final dur = _fmtTime(hooks.duration());
          final uri = _xmlEscape(_currentUri ?? '');
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
          final dur = _fmtTime(hooks.duration());
          final uri = _xmlEscape(_currentUri ?? '');
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
          await _soapResponse(req, service, action,
              '<Actions>Play,Pause,Stop,Seek</Actions>');
          return;
        default:
          await _soapResponse(req, service, action, '');
          return;
      }
    }

    if (service.contains('RenderingControl')) {
      switch (action) {
        case 'SetVolume':
          final v = int.tryParse(_extract(body, 'DesiredVolume')) ?? -1;
          if (v >= 0 && v <= 100) hooks.onSetVolume(v / 100.0);
          await _soapResponse(req, service, action, '');
          return;
        case 'GetVolume':
          final vol = (hooks.volume().clamp(0.0, 1.0) * 100).round();
          await _soapResponse(req, service, action,
              '<CurrentVolume>$vol</CurrentVolume>');
          return;
        case 'GetMute':
          await _soapResponse(req, service, action, '<CurrentMute>0</CurrentMute>');
          return;
        case 'SetMute':
          await _soapResponse(req, service, action, '');
          return;
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
        default:
          await _soapResponse(req, service, action, '');
          return;
      }
    }

    req.response.statusCode = 404;
    await req.response.close();
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
    req.response.contentLength = data.length;
    req.response.add(data);
    await req.response.close();
  }

  // ==================== 描述文件 ====================

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
      '<root xmlns="urn:schemas-upnp-org:device-1-0">'
      '<specVersion><major>1</major><minor>0</minor></specVersion>'
      '<device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>${_xmlEscape(_name)}</friendlyName>'
      '<manufacturer>OMPlayer</manufacturer>'
      '<modelDescription>OMPlayer DLNA Renderer</modelDescription>'
      '<modelName>OMPlayer</modelName>'
      '<modelNumber>1.0</modelNumber>'
      '<UDN>uuid:$_uuid</UDN>'
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
