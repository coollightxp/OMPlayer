import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/epg_source.dart';
import '../models/player_settings.dart';
import '../models/playlist_source.dart';
import '../models/reservation.dart';
import 'auto_launch.dart';
import 'cast_log.dart';
import 'dlna_service.dart';
import 'win_hotkeys.dart';
import 'fvp_register.dart';
import 'media_capture_service.dart';
import 'native_capture.dart';
import 'remote_admin_service.dart';
import 'reservation_manager.dart';
import 'source_manager.dart';
import 'web_launch.dart';
import 'network_monitor.dart';

/// 播放器状态
enum PlayerState { idle, loading, playing, paused, error, ended, waitingForNetwork }

/// 播放器控制器 - 使用 ChangeNotifier 进行状态管理
class PlayerController extends ChangeNotifier {
  VideoPlayerController? _videoController;
  PlayerSettings _settings = const PlayerSettings();

  PlayerState _state = PlayerState.idle;
  Channel? _currentChannel;
  double _volume = 0.8;
  double _brightness = 0.8;
  List<ChannelCategory> _categories = [];

  // 新增服务
  final SourceManager sourceManager = SourceManager();
  final ReservationManager reservationManager = ReservationManager();
  final MediaCaptureService captureService = MediaCaptureService();

  // DLNA 投屏接收服务（接收其它设备推送的视频）
  final DlnaService dlnaService = DlnaService();
  bool _isCasting = false;
  Channel? _preCastChannel; // 投屏前的频道，用于断开后恢复

  // 局域网 Web 管理服务（手机扫码后增删改直播源/EPG）
  final RemoteAdminService remoteAdminService = RemoteAdminService();
  String _remoteAdminUrl = '';
  String get remoteAdminUrl => _remoteAdminUrl;
  bool get remoteAdminRunning => remoteAdminService.isRunning;

  // NumLock 守护已移至 Windows runner（见文件末说明）

  // 投屏诊断日志路径（设置面板展示给用户反馈问题）
  String _castLogPath = '';
  String get castLogPath => _castLogPath;

  // 投屏卡顿看门狗：状态仍为"播放中"但播放位置长时间不推进时，
  // 说明网络流被静默掐断（常见于 HTTP-FLV/视频号直播），需要自愈
  int _watchPosMs = -1;
  DateTime? _watchAdvanceAt;
  bool _stallNudged = false;
  // 整场投屏是否已重建过（所有自愈路径统一守门，只重建一次）
  bool _castReinitDone = false;

  // 投屏诊断：1 秒一次状态采样 + buffering 持续超时自愈
  DateTime? _lastCastTickAt;
  bool _wasBuffering = false;
  DateTime? _bufferingSince;

  // 有声无画面看门狗：音频在播但视频尺寸长时间为 0（解码链视频轨没起来）
  DateTime? _noVideoSince;
  // 投屏 initialize 15s 超时后，用同一 URL 原地重拉一次（偶发首拉视频轨不起）
  bool _castInitRetried = false;

  // 播放代际令牌：每次发起播放 +1；initialize 是异步的，Stop→换片等场景会
  // 并发触发多个 _playCurrentSource，迟到的 initialize 完成时若代际已过期，
  // 必须静默丢弃，不能覆盖当前播放器（否则会出现直播流覆盖点播、进度条消失、
  // 假 error 覆盖层 + 旧音频仍在响等问题）
  int _playGeneration = 0;
  // 绑定到当前 controller 的事件监听闭包（dispose 时精确移除）
  VoidCallback? _videoListenerClosure;

  // 投屏 Stop 延迟恢复：发送端换片的标准信令是 Stop→SetURI→Play（间隔仅
  // 几十毫秒），立即恢复上次频道会与马上到达的新投屏并发拉流。延迟 800ms，
  // 期间收到新投屏则取消恢复
  Timer? _castRestoreTimer;
  // 投屏点播播完（ended）兜底：上报 STOPPED 后等 5 秒，发送端若没主动
  // Stop/换片，就自动切回投屏前频道，避免停在最后一帧
  Timer? _castEndedTimer;

  // 静音状态
  bool _isMuted = false;
  double _volumeBeforeMute = 0.8;

  bool _isLoadingPlaylist = false;
  bool _isLoadingEpg = false;
  String? _lastError;
  bool _isFullscreen = false;

  // 录制状态（fvp 原生录制 / 网页 MediaRecorder 录制）
  bool _isRecording = false;
  String? _recordPath;

  // 网页录制：MediaRecorder 分块（base64）经 JS bridge 追加写入 .webm
  int _webRecBytes = 0;
  Completer<void>? _webRecDone;

  // 播放进度定时刷新（进度条/倒计时）
  Timer? _tickTimer;

  PlayerState get state => _state;
  Channel? get currentChannel => _currentChannel;
  double get volume => _volume;
  double get brightness => _brightness;
  PlayerSettings get settings => _settings;
  VideoPlayerController? get videoController => _videoController;
  List<ChannelCategory> get categories => _categories;
  bool get isLoadingPlaylist => _isLoadingPlaylist;
  bool get isLoadingEpg => _isLoadingEpg;
  String? get lastError => _lastError;
  bool get isRecording => _isRecording;

  /// 网页录制已落盘字节数（录制指示器显示）
  int get webRecordingBytes => _webRecBytes;
  bool get isDesktop => !kIsWeb && MediaCaptureService.isDesktop;
  bool get isFullscreen => _isFullscreen;
  bool get isCasting => _isCasting;
  bool get isMuted => _isMuted;

  bool get isPlaying =>
      _webPageActive ? _webPlaying : _state == PlayerState.playing;
  bool get isInitialized =>
      _videoController != null && _videoController!.value.isInitialized;

  PlayerController() {
    _init();
  }

  Future<void> _init() async {
    await _loadSettings();
    await sourceManager.loadFromPrefs();
    await reservationManager.init(_onReservationTriggered);

    // 启动网络监控：开机启动时可能网络未就绪，需要检测并重试
    NetworkMonitor.instance.start();
    NetworkMonitor.instance.onNetworkChanged.listen(_onNetworkChanged);
    // 投屏诊断日志路径（供设置面板展示）
    CastLog.path().then((p) {
      if (p.isNotEmpty && _castLogPath != p) {
        _castLogPath = p;
        notifyListeners();
      }
    });
    // 播放中每 500ms 刷新一次（进度条、倒计时等）
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _checkCastStall();
      if (_videoController != null &&
          _videoController!.value.isInitialized) {
        notifyListeners();
      }
    });

    // 如果有选中的播放列表，加载频道；否则保持空列表，等用户添加
    if (sourceManager.currentPlaylist != null) {
      await refreshChannels();
    }

    // 如果有选中的 EPG，加载节目单
    if (sourceManager.currentEpg != null) {
      await refreshEpg();
    }

    // 先启动 DLNA 投屏接收服务（不等系统值初始化，避免被阻塞）；
    // 用户可在设置中关闭
    if (_settings.dlnaEnabled) {
      _startDlna();
    }
    // 启动局域网 Web 管理服务（手机扫码管理直播源/EPG）
    if (_settings.remoteAdminEnabled) {
      _startRemoteAdmin();
    }
    _initSystemValues();

    // 频道加载完毕后，恢复上次退出时播放的频道
    await restoreLastChannel();

    notifyListeners();
  }

  // ==================== 网络状态处理 ====================

  /// 网络状态变化回调
  void _onNetworkChanged(bool online) {
    if (online) {
      _onNetworkRestored();
    } else {
      // 网络断开：暂停播放
      if (_webPageActive) {
        _webEval?.call('window.__omPause && window.__omPause()');
      } else if (_videoController != null) {
        _videoController?.pause();
      }
      _state = PlayerState.paused;
      notifyListeners();
    }
  }

  /// 网络恢复：补加载启动时因无网未载入的频道列表/EPG（已载入的不管），
  /// 并恢复播放
  Future<void> _onNetworkRestored() async {
    // 频道列表为空且已选播放列表：启动时无网加载失败，补加载
    if (_categories.isEmpty &&
        sourceManager.currentPlaylist != null &&
        !_isLoadingPlaylist) {
      await refreshChannels();
    }
    // EPG 无数据且已选 EPG 源：补加载
    if (sourceManager.cachedEpg.isEmpty &&
        sourceManager.currentEpg != null &&
        !_isLoadingEpg) {
      await refreshEpg();
    }
    if (_state == PlayerState.waitingForNetwork) {
      if (_currentChannel != null) {
        // 之前在等待网络：重新播放当前频道
        _state = PlayerState.loading;
        notifyListeners();
        await playChannel(_currentChannel!);
      } else {
        // 启动时无网，playChannel 在等网阶段返回、频道从未赋值：
        // 重新恢复上次播放的频道（无记录时回到空闲态）
        _state = PlayerState.idle;
        await restoreLastChannel();
      }
    } else if (_state == PlayerState.paused && _webPageActive) {
      // 网页频道：网络恢复后尝试继续播放
      _webEval?.call('window.__omResume && window.__omResume()');
    } else if (_state == PlayerState.paused && _videoController != null) {
      // 普通频道：网络恢复后继续播放
      _videoController?.play();
    }
  }

  /// 等待网络可用（最多等 30 秒），返回是否有网
  Future<bool> _waitForNetwork() async {
    if (NetworkMonitor.instance.hasNetwork) return true;
    _state = PlayerState.waitingForNetwork;
    notifyListeners();
    return NetworkMonitor.instance.waitForNetwork(
      timeout: const Duration(seconds: 30),
    );
  }

  // ==================== 上次播放记忆 ====================

  static const _kLastChannel = 'last_channel_v1';

  /// 播放成功后记录当前频道，供下次启动恢复
  Future<void> _saveLastChannel() async {
    // 投屏会话不记录：投屏链接是临时的（如手机推来的抖音直播），
    // 记录后下次启动会尝试恢复一个已失效的投屏地址
    if (_isCasting) return;
    final ch = _currentChannel;
    if (ch == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      final data = {
        'id': ch.id,
        'name': ch.name,
        'logoUrl': ch.logoUrl,
        'tvgId': ch.tvgId,
        'tvgName': ch.tvgName,
        'groupTitle': ch.groupTitle,
        'categoryId': ch.categoryId,
        'streamUrls': ch.streamUrls,
        'sourceIndex': _sourceIndex,
        'userAgent': ch.userAgent,
      };
      await p.setString(_kLastChannel, jsonEncode(data));
    } catch (_) {}
  }

  /// 启动时恢复上次播放的频道：优先在当前播放列表中精确匹配，
  /// 匹配不到则用记录的播放地址构造临时频道播放
  Future<void> restoreLastChannel() async {
    try {
      final p = await SharedPreferences.getInstance();
      final str = p.getString(_kLastChannel);
      if (str == null || str.isEmpty) return;
      final Map<String, dynamic> data =
          jsonDecode(str) as Map<String, dynamic>;
      final urls = (data['streamUrls'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      if (urls.isEmpty) return;
      final id = data['id'] as String? ?? '';
      final name = data['name'] as String? ?? '';
      final srcIdx = (data['sourceIndex'] as int?) ?? 0;

      // 1) 在已加载分类中按频道 ID 精确查找
      Channel? target;
      if (id.isNotEmpty) {
        target = _findChannelById(id);
      }
      // 2) 没找到则用记录的地址列表 + 元数据构造临时频道
      target ??= Channel(
        id: id.isNotEmpty ? id : '__last_played__',
        name: name,
        logoUrl: data['logoUrl'] as String? ?? '',
        streamUrls: urls,
        categoryId: data['categoryId'] as String? ?? '',
        tvgId: data['tvgId'] as String? ?? '',
        tvgName: data['tvgName'] as String? ?? '',
        groupTitle: data['groupTitle'] as String? ?? '',
        userAgent: data['userAgent'] as String? ?? '',
      );
      _sourceIndex =
          srcIdx < target.streamUrls.length ? srcIdx : 0;
      // 上次是网页频道：启动时也自动打开网页播放
      await playChannel(target);
      // 开机时系统网络/DNS 可能尚未就绪，首次拉流偶发超时失败。
      // 3 秒后在用户无操作（未手动切台/未投屏）的前提下自动重试一次
      if (_state == PlayerState.error &&
          !_isCasting &&
          identical(_currentChannel, target)) {
        await Future.delayed(const Duration(seconds: 3));
        if (_state == PlayerState.error &&
            !_isCasting &&
            identical(_currentChannel, target)) {
          await playChannel(target);
        }
      }
    } catch (_) {}
  }

  /// DLNA 服务状态（设置面板展示，方便确认是否开启）
  String _dlnaName = '';
  bool _dlnaRunning = false;
  String _dlnaEndpoint = '';
  String get dlnaName => _dlnaName;
  bool get dlnaRunning => _dlnaRunning;
  String get dlnaEndpoint => _dlnaEndpoint;

  /// 启动 DLNA 接收服务：设备名 = OMPlayer + 机器唯一标识
  Future<void> _startDlna() async {
    if (dlnaService.isRunning) {
      // 已运行（用户刚重新打开开关）：只刷新状态展示
      _dlnaName = dlnaService.deviceName;
      _dlnaRunning = true;
      _dlnaEndpoint = dlnaService.deviceEndpoint;
      notifyListeners();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      var uuid = prefs.getString('dlna_uuid') ?? '';
      if (uuid.isEmpty) {
        final rnd = Random();
        uuid = List.generate(
                8, (_) => '0123456789abcdef'[rnd.nextInt(16)])
            .join();
        await prefs.setString('dlna_uuid', uuid);
      }
      await dlnaService.start(
        uuid: uuid,
        hooks: DlnaHooks(
          onPlay: (url, title) => playCastUrl(url, title),
          onPause: () async {
            if (_videoController != null &&
                _videoController!.value.isPlaying) {
              await _videoController!.pause();
              _state = PlayerState.paused;
              notifyListeners();
            }
          },
          onResume: () async {
            if (_videoController == null ||
                !_videoController!.value.isInitialized) {
              return;
            }
            if (!_videoController!.value.isPlaying) {
              await _videoController!.play();
              _state = PlayerState.playing;
              notifyListeners();
            }
          },
          onStop: () => stopCastAndRestore(),
          onSeek: (p) => seekTo(p),
          onSetVolume: (v) => setVolume(v),
          onSetMute: (m) => setMuted(m),
          transportState: () {
            switch (_state) {
              case PlayerState.playing:
                return 'PLAYING';
              case PlayerState.paused:
                return 'PAUSED_PLAYBACK';
              case PlayerState.loading:
                // 标准状态：媒体正在准备，发送端此时不应判定为失败/重试
                return 'TRANSITIONING';
              default:
                return 'STOPPED';
            }
          },
          position: () => position,
          duration: () => duration,
          volume: () => _volume,
          muted: () => _isMuted,
        ),
      );
      _dlnaName = dlnaService.deviceName;
      _dlnaRunning = dlnaService.isRunning;
      _dlnaEndpoint = dlnaService.deviceEndpoint;
    } catch (_) {
      _dlnaRunning = false;
    }
    notifyListeners();
  }

  /// 停止 DLNA 投屏接收服务（设置面板开关）
  void _stopDlna() {
    dlnaService.stop();
    _dlnaRunning = false;
    _dlnaEndpoint = '';
    notifyListeners();
  }

  /// 启动局域网 Web 管理服务
  Future<void> _startRemoteAdmin() async {
    if (remoteAdminService.isRunning) {
      _remoteAdminUrl = remoteAdminService.endpoint;
      notifyListeners();
      return;
    }
    try {
      await remoteAdminService.start(
        hooks: RemoteAdminHooks(
          getSnapshot: _remoteAdminSnapshot,
          applySnapshot: _remoteAdminApply,
          refresh: (kind) async {
            if (kind == 'epgs') {
              await refreshEpg();
            } else {
              await refreshChannels();
            }
          },
        ),
      );
      _remoteAdminUrl = remoteAdminService.endpoint;
    } catch (_) {
      _remoteAdminUrl = '';
    }
    notifyListeners();
  }

  void _stopRemoteAdmin() {
    remoteAdminService.stop();
    _remoteAdminUrl = '';
    notifyListeners();
  }

  Future<Map<String, dynamic>> _remoteAdminSnapshot() async {
    return {
      'playlists': sourceManager.playlists.map((e) => e.toJson()).toList(),
      'currentPlaylistId': sourceManager.currentPlaylistId,
      'epgs': sourceManager.epgs.map((e) => e.toJson()).toList(),
      'currentEpgId': sourceManager.currentEpgId,
    };
  }

  Future<void> _remoteAdminApply(Map<String, dynamic> data) async {
    final rawPl = (data['playlists'] as List?) ?? const [];
    final playlists = rawPl
        .whereType<Map>()
        .map((m) => PlaylistSource.fromJson(
            _normalizeRemoteItem(m.cast<String, dynamic>())))
        .toList();
    final newPlId = data['currentPlaylistId']?.toString();
    final oldPlId = sourceManager.currentPlaylistId;
    final oldPlUrl = sourceManager.currentPlaylist?.url;
    final plExists = await sourceManager.replacePlaylists(playlists, newPlId);
    if (plExists) {
      final cur = sourceManager.currentPlaylist!;
      if (cur.id != oldPlId || cur.url != oldPlUrl) {
        await refreshChannels();
      }
    } else if (oldPlId != null) {
      // 当前源被删除：清空频道
      _categories = [];
      _currentChannel = null;
      notifyListeners();
    }

    final rawEpg = (data['epgs'] as List?) ?? const [];
    final epgs = rawEpg
        .whereType<Map>()
        .map((m) => EpgSource.fromJson(
            _normalizeRemoteItem(m.cast<String, dynamic>())))
        .toList();
    final newEpgId = data['currentEpgId']?.toString();
    final oldEpgId = sourceManager.currentEpgId;
    await sourceManager.replaceEpgs(epgs, newEpgId);
    if (sourceManager.currentEpg != null &&
        sourceManager.currentEpgId != oldEpgId) {
      await refreshEpg();
    }
    notifyListeners();
  }

  /// 手机端新建项可能缺少 addedAt 等字段，补默认值
  Map<String, dynamic> _normalizeRemoteItem(Map<String, dynamic> j) {
    if (j['id'] is! String || (j['id'] as String).isEmpty) {
      j['id'] = DateTime.now().millisecondsSinceEpoch.toString();
    }
    if (j['name'] is! String) j['name'] = '未命名';
    if (j['url'] is! String) j['url'] = '';
    if (j['type'] is! String) j['type'] = 'url';
    if (j['format'] is! String) j['format'] = 'unknown';
    if (j['addedAt'] is! String) {
      j['addedAt'] = DateTime.now().toIso8601String();
    }
    return j;
  }

  /// 播放投屏推送的 URL（记录投屏前频道用于断开恢复）
  Future<void> playCastUrl(String url, String title) async {
    // 紧接 Stop 到达的新投屏：取消挂起的"恢复上次频道"和"播完兜底"
    _castRestoreTimer?.cancel();
    _castRestoreTimer = null;
    _castEndedTimer?.cancel();
    _castEndedTimer = null;
    _preCastChannel ??=
        (_currentChannel?.id.startsWith('__dlna_cast__') ?? false)
            ? null
            : _currentChannel;
    _isCasting = true;
    // 重置卡顿看门狗
    _watchPosMs = -1;
    _watchAdvanceAt = null;
    _stallNudged = false;
    _castReinitDone = false;
    _lastCastTickAt = null;
    _wasBuffering = false;
    _bufferingSince = null;
    _noVideoSince = null;
    _castInitRetried = false;
    CastLog.write(
        'cast play: title="$title" url=$url');
    final cast = Channel(
      id: '__dlna_cast__',
      name: title.isEmpty ? 'DLNA 投屏' : title,
      streamUrls: [url],
      categoryId: 'dlna',
    );
    await playChannel(cast);
  }

  /// 投屏端停止：延迟 800ms 再恢复。
  /// 发送端换片信令通常是 Stop→(几十毫秒)→SetAVTransportURI→Play，
  /// 立即恢复会让"恢复直播"与"新投屏"两路 initialize 并发，迟到的直播流
  /// 初始化会覆盖点播（进度条消失、假重试、有声无画的根因）。
  Future<void> stopCastAndRestore() async {
    if (!_isCasting) return;
    // 恢复延迟已在途：保持原 timer，不取消/重置。
    // 看门狗或重复点击若不断重置这个 timer，会导致几十秒无法真正断开
    if (_castRestoreTimer != null) return;
    _castEndedTimer?.cancel();
    _castEndedTimer = null;
    _castRestoreTimer = Timer(const Duration(milliseconds: 800), () {
      _castRestoreTimer = null;
      _doStopCastAndRestore();
    });
  }

  /// 投屏端断开/停止后的实际恢复逻辑
  Future<void> _doStopCastAndRestore() async {
    if (!_isCasting) return;
    CastLog.write('cast stopped by sender, restore previous channel');
    _isCasting = false;
    _watchPosMs = -1;
    _watchAdvanceAt = null;
    // 清空 DLNA 服务端当前媒体：发送端轮询 GetMediaInfo 时看到无媒体，
    // 即可知道投屏已结束，不再显示"已连接"。
    dlnaService.clearCurrentMedia();
    final restore = _preCastChannel;
    _preCastChannel = null;
    if (restore != null) {
      await playChannel(restore);
    } else {
      await _disposeVideoController();
      WakelockPlus.disable();
      _state = PlayerState.idle;
      notifyListeners();
    }
  }

  /// 预约触发回调 - 自动切换/录制
  Future<void> _onReservationTriggered(ProgramReservation r) async {
    Channel? channel;
    if (r.autoSwitch || (r.autoRecord && isDesktop)) {
      // 优先使用预约时记录的播放地址直接播放（不依赖当前播放列表）
      if (r.streamUrls.isNotEmpty) {
        channel = Channel(
          id: r.channelId,
          name: r.channelName.isNotEmpty ? r.channelName : r.programTitle,
          logoUrl: r.logoUrl,
          streamUrls: r.streamUrls,
          categoryId: '',
          tvgId: r.tvgId,
          tvgName: r.tvgName,
        );
      } else {
        // 兼容旧预约记录：按 ID/tvgId/名称从当前播放列表反查
        channel = _resolveReservationChannel(r);
      }
    }
    if (r.autoSwitch && channel != null) {
      await playChannel(channel);
    }
    if (r.autoRecord && isDesktop && channel != null) {
      // 保证录制针对的是预约频道
      if (_currentChannel?.id != channel.id) {
        await playChannel(channel);
      }
      startRecording();
    }
    notifyListeners();
  }

  /// 解析预约对应的频道：先按播放列表频道 ID 精确查找，
  /// 失败则兼容旧数据（存的是 EPG 频道 ID）按 tvgId/名称匹配
  Channel? _resolveReservationChannel(ProgramReservation r) {
    final byId = _findChannelById(r.channelId);
    if (byId != null) return byId;
    // tvgId 精确匹配
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        if (ch.tvgId.isNotEmpty && ch.tvgId == r.channelId) return ch;
      }
    }
    // 名称模糊匹配（EPG 频道 ID 或预约记录的频道名）
    for (final key in [r.channelId, r.channelName]) {
      final lower = key.toLowerCase();
      if (lower.isEmpty) continue;
      for (final cat in _categories) {
        for (final ch in cat.channels) {
          if (ch.tvgName.isNotEmpty &&
              ch.tvgName.toLowerCase() == lower) {
            return ch;
          }
          final name = ch.name.toLowerCase();
          if (name.contains(lower) || lower.contains(name)) {
            return ch;
          }
        }
      }
    }
    return null;
  }

  Channel? _findChannelById(String channelId) {
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        if (ch.id == channelId) return ch;
      }
    }
    return null;
  }

  /// 初始化系统音量和亮度
  Future<void> _initSystemValues() async {
    try {
      _brightness = await ScreenBrightness.instance.application;
    } catch (_) {
      _brightness = _settings.defaultBrightness;
    }
    try {
      final vol = await VolumeController.instance.getVolume();
      _volume = vol;
    } catch (_) {
      _volume = _settings.defaultVolume;
    }
    notifyListeners();
  }

  // ==================== 频道加载 ====================

  /// 刷新当前播放列表的频道
  Future<void> refreshChannels() async {
    _isLoadingPlaylist = true;
    _lastError = null;
    notifyListeners();
    try {
      _categories = await sourceManager.loadChannels();
    } catch (e) {
      _lastError = '加载频道列表失败: $e';
    } finally {
      _isLoadingPlaylist = false;
      notifyListeners();
    }
  }

  /// 刷新 EPG 数据
  Future<void> refreshEpg() async {
    _isLoadingEpg = true;
    notifyListeners();
    try {
      await sourceManager.loadEpg();
    } catch (e) {
      _lastError = '加载 EPG 失败: $e';
    } finally {
      _isLoadingEpg = false;
      notifyListeners();
    }
  }

  // ==================== 播放控制 ====================

  /// 当前播放源索引（同名频道合并后有多个源）
  int _sourceIndex = 0;
  int get sourceIndex => _sourceIndex;
  int get sourceCount => _currentChannel?.streamUrls.length ?? 0;
  bool get hasPrevSource => _sourceIndex > 0;
  bool get hasNextSource => _sourceIndex < sourceCount - 1;

  /// 播放指定频道（从第一个源开始，失败自动尝试下一个源）
  Future<void> playChannel(Channel channel) async {
    // 无网络时等待网络（开机启动时系统网络可能未就绪）
    if (!await _waitForNetwork()) {
      // 30 秒内仍无网络，保持等待状态，后台继续检测
      return;
    }
    // 网页频道（webview:// 包装的网站）：停掉视频，切到内嵌网页控件，
    // 由网站自身的播放器播放；节目单/信息面板浮层继续显示在其上
    if (channel.isWebPage) {
      await _openWebPageChannel(channel);
      return;
    }
    _webPageActive = false;
    _webPageForeground = false;
    _currentChannel = channel;
    _sourceIndex = 0;
    await _playCurrentSource();
  }

  /// 是否处于网页频道内嵌模式（PlayerScreen 据此显示内嵌网页控件）
  bool _webPageActive = false;
  bool get webPageActive => _webPageActive;

  /// 网页频道的 WebView 控制器（Dart 侧调用网页 JS 用，如重置光标隐藏定时器）
  dynamic webController;

  /// 网页频道的 FocusNode（用户交互后请求 WebView 焦点用）
  FocusNode? webFocusNode;

  /// 网页是否已在【前台】播放（网页在后台缓冲时为 false，视频层保持
  /// 黑屏占位；网页播放器真正带声音起播后由 JS 回调置 true，
  /// 网页推到最前、原视频层隐藏）
  bool _webPageForeground = false;
  bool get webPageForeground => _webPageForeground;

  /// 网页内视频是否处于播放态（由网页 play/pause 事件回传，
  /// 供底部面板播放按钮显示正确图标）
  bool _webPlaying = false;

  /// ===== 网页频道控制桥（由内嵌 WebView 注册/注销）=====
  /// 执行 JS 并返回结果
  Future<dynamic> Function(String)? _webEval;

  /// 截取网页画面，返回 PNG 字节
  Future<List<int>?> Function()? _webScreenshot;

  /// 网页内播放/暂停切换 JS（递归同源 iframe，只操作可见面积最大的
  /// 主视频——页面常带隐藏预览/广告播放器，"任一个在播就全暂停"会
  /// 把主视频误停）。
  /// 暂停时先代点站点自身的大播放钮（央视频 CMG 等播放器只认自身
  /// 按钮激活，纯 video.play() 会被立即暂停），再兜底 play()。
  /// 返回 '1' 表示切换后暂停，'0' 表示播放中，'2' 表示没找到可见视频。
  static const _webToggleJs = r'''
(function(){
  function allVideos(root){
    var out = Array.prototype.slice.call(root.querySelectorAll('video'));
    var frames = root.querySelectorAll('iframe');
    for (var i=0;i<frames.length;i++){
      try { var d = frames[i].contentDocument;
            if (d) out = out.concat(allVideos(d)); } catch(e) {}
    }
    return out;
  }
  function collectDocs(root, out){
    out.push(root);
    var frames = root.querySelectorAll('iframe');
    for (var i=0;i<frames.length;i++){
      try { var d = frames[i].contentDocument;
            if (d) collectDocs(d, out); } catch(e) {}
    }
  }
  // 代点网站大播放按钮（VideoJS 等封装播放器不认 raw video.play()）
  function clickBigPlay(){
    var docs = [];
    collectDocs(document, docs);
    for (var di=0; di<docs.length; di++){
      var d = docs[di];
      var w = d.defaultView;
      var ww = (w.innerWidth || 1), hh = (w.innerHeight || 1);
      var pts = [[ww/2, hh/2], [ww/2, hh*0.3], [ww/2, hh*0.7],
                 [ww*0.3, hh/2], [ww*0.7, hh/2]];
      var vids = d.querySelectorAll('video');
      for (var vi=0;vi<vids.length;vi++)
        vids[vi].style.setProperty('pointer-events','none','important');
      for (var k=0;k<pts.length;k++){
        var el = null;
        try { el = d.elementFromPoint(pts[k][0], pts[k][1]); } catch(e){}
        for (var vi=0;vi<vids.length;vi++){
          try { vids[vi].style.removeProperty('pointer-events'); } catch(e){}
        }
        var n = el, dep = 0;
        while (n && n !== d && dep < 6){
          var tg = (n.tagName || '').toLowerCase();
          var role = n.getAttribute ? n.getAttribute('role') : '';
          var cls = ((n.className && n.className.toString) ? n.className.toString() : '')
              + ' ' + (n.id || '');
          if (tg === 'button' || role === 'button'
              || /play|start|poster|cover|bigplay/i.test(cls)) {
            try { n.click(); } catch(e){}
            return true;
          }
          n = n.parentNode; dep++;
        }
      }
    }
    return false;
  }
  var vs = allVideos(document);
  var anyPlaying = false;
  for (var i=0;i<vs.length;i++){
    if (!vs[i].paused) { anyPlaying = true; break; }
  }
  // 通知 kick()：暂停时不再自动拉起
  try { window.__omUserPaused = anyPlaying; } catch(e) {}
  if (anyPlaying) {
    // 暂停：raw video.pause() 即可
    for (var i=0;i<vs.length;i++){ try { vs[i].pause(); } catch(e){} }
    // VideoJS 等封装播放器也暂停
    try {
      if (window.videojs && videojs.getAllPlayers) {
        var ps = videojs.getAllPlayers();
        for (var pi=0; pi<ps.length; pi++){
          try { ps[pi].pause(); } catch(e){}
        }
      }
    } catch(e) {}
  } else {
    // 播放：先 VideoJS API，再 raw play()，最后代点网站播放钮
    try {
      if (window.videojs && videojs.getAllPlayers) {
        var ps = videojs.getAllPlayers();
        for (var pi=0; pi<ps.length; pi++){
          try { ps[pi].muted(false); ps[pi].play(); } catch(e){}
        }
      }
    } catch(e) {}
    for (var i=0;i<vs.length;i++){
      var v = vs[i];
      try {
        v.removeAttribute('muted'); v.muted = false;
        var wv = window.__omVol;
        v.volume = (typeof wv === 'number') ? wv : 1;
        var p = v.play(); if (p && p.catch) p.catch(function(){});
      } catch(e) {}
    }
    clickBigPlay();
  }
  return anyPlaying ? '1' : '0';
})();
''';

  /// 注册网页控制桥（WebView 创建后）
  void attachWebBridge({
    required Future<dynamic> Function(String) eval,
    required Future<List<int>?> Function() screenshot,
  }) {
    _webEval = eval;
    _webScreenshot = screenshot;
    _webPlaying = true;
    // 网页前台播放时鼠标静止 3 秒隐藏光标（原生实现，CSS 管不到跨域 iframe）
    WinHotkeys().setCursorHide(true);
    // 把当前音量同步给页面 video（kick 起播锁定后不再改写音量）
    _applyWebVolume();
    // 网页频道用 CSS filter 调光（系统亮度 API 管不到 WebView2）
    _applyWebBrightness();
  }

  /// 注销网页控制桥（WebView 销毁前）
  void detachWebBridge() {
    _webEval = null;
    _webScreenshot = null;
    _webPlaying = false;
    WinHotkeys().setCursorHide(false);
  }

  /// 网页内播放/暂停状态回传
  void setWebPlaying(bool playing) {
    if (_webPlaying == playing) return;
    _webPlaying = playing;
    notifyListeners();
  }

  /// 网页起播后推到前台（由内嵌网页的 JS 回调触发）
  void setWebForeground(bool value) {
    if (_webPageForeground == value) return;
    _webPageForeground = value;
    // 起播成功：把 App 音量写入页面 video（attachWebBridge 时页面
    // 可能还没有 video 元素，这里才是真正生效的时机）
    if (value) _applyWebVolume();
    notifyListeners();
  }

  /// 打开网页频道（TVBox webview:// 链接，如央视网网站播放器）
  Future<void> _openWebPageChannel(Channel channel) async {
    // 已在播放同一个网页频道：保持现状（网页已在前台/后台缓冲中），
    // 不要把前景状态重置回黑屏缓冲、重新走一遍探测流程
    if (_webPageActive && _currentChannel?.id == channel.id) {
      return;
    }
    _resetWebRecording();
    await _disposeVideoController();
    _currentChannel = channel;
    _sourceIndex = 0;
    _state = PlayerState.idle;
    await _saveLastChannel();
    // Windows/Android/macOS/Web：使用窗体内嵌网页控件（信息/节目单/EPG
    // 浮层叠加其上，原视频控件隐藏）；Linux 无内嵌实现，回退系统浏览器
    if (await supportsEmbeddedWeb()) {
      // 网页先在后台全屏缓冲（视频位保持黑屏），起播后再推到前台
      _webPageActive = true;
      _webPageForeground = false;
      notifyListeners();
    } else {
      await launchExternal(channel.webPageUrl);
    }
  }

  /// 退出网页频道内嵌模式（隐藏网页控件，回到普通播放界面）
  void exitWebPage() {
    if (!_webPageActive) return;
    _resetWebRecording();
    _webPageActive = false;
    _webPageForeground = false;
    WinHotkeys().setCursorHide(false);
    notifyListeners();
  }

  /// 换台/退出网页时复位网页录制状态（旧 WebView 销毁后 JS 上下文
  /// 随之消失，无法再取回末尾分块，已落盘部分保留为可用文件）
  void _resetWebRecording() {
    if (!_isRecording || !_webPageActive) return;
    _isRecording = false;
    _recordPath = null;
    _webRecDone = null;
    _webRecBytes = 0;
  }

  /// 切换到上一个播放源
  Future<void> prevSource() async {
    if (!hasPrevSource) return;
    _sourceIndex--;
    await _playCurrentSource();
  }

  /// 切换到下一个播放源
  Future<void> nextSource() async {
    if (!hasNextSource) return;
    _sourceIndex++;
    await _playCurrentSource();
  }

  /// 上一个频道
  Future<void> previousChannel() => playAdjacentChannel(-1);

  /// 下一个频道
  Future<void> nextChannel() => playAdjacentChannel(1);

  /// 按偏移量切换频道（跨分类、循环）
  Future<void> playAdjacentChannel(int delta) async {
    final all = [for (final cat in _categories) ...cat.channels];
    if (all.isEmpty) return;
    if (_currentChannel == null) {
      await playChannel(all.first);
      return;
    }
    final idx = all.indexWhere((c) => c.id == _currentChannel!.id);
    if (idx < 0) {
      await playChannel(all.first);
      return;
    }
    final next = (idx + delta + all.length) % all.length;
    await playChannel(all[next]);
  }

  // ==================== 频道序号（数字选台） ====================

  /// 全部频道按播放列表顺序展平（序号 = 下标 + 1）
  List<Channel> get flatChannels =>
      [for (final cat in _categories) ...cat.channels];

  /// 频道序号（1 起），不在列表中返回 null
  int? channelNumberOf(Channel? ch) {
    if (ch == null) return null;
    final idx = flatChannels.indexWhere((c) => c.id == ch.id);
    return idx < 0 ? null : idx + 1;
  }

  /// 当前频道序号（1 起）
  int? get currentChannelNumber => channelNumberOf(_currentChannel);

  /// 按序号跳台（1 起），序号无效时忽略
  Future<void> playChannelByNumber(int number) async {
    final all = flatChannels;
    if (number < 1 || number > all.length) return;
    await playChannel(all[number - 1]);
  }

  /// 播放当前频道的当前源；初始化失败时自动尝试下一个源。
  /// 使用代际令牌防止并发调用（Stop→换片、快速切台）的迟到 initialize
  /// 覆盖当前播放器。
  Future<void> _playCurrentSource() async {
    final channel = _currentChannel;
    if (channel == null || channel.streamUrls.isEmpty) {
      _state = PlayerState.error;
      notifyListeners();
      return;
    }
    if (_sourceIndex < 0 || _sourceIndex >= channel.streamUrls.length) {
      _sourceIndex = 0;
    }
    final gen = ++_playGeneration;
    _state = PlayerState.loading;
    notifyListeners();

    // 缓冲设置即时生效：每次起播前按当前设置重新注册 fvp 选项，
    // 不必重启程序（registerWith 的全局选项对之后创建的播放器生效）
    registerFvp(bufferSeconds: _settings.bufferSeconds);

    await _disposeVideoController();

    // 频道声明的自定义 UA（M3U http-user-agent）：部分源（如 APTV）
    // 必须带指定 UA，否则返回 404/广告。fvp 经 ffmpeg 透传 HTTP 头。
    final headers = <String, String>{};
    if (channel.userAgent.trim().isNotEmpty) {
      headers['User-Agent'] = channel.userAgent.trim();
    }
    final c = VideoPlayerController.networkUrl(
      Uri.parse(channel.streamUrls[_sourceIndex]),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      // video_player 2.8.x 该参数为非空 Map（默认空）；空 map 时
      // fvp 不会设置 avio.headers，与不传等价
      httpHeaders: headers,
    );
    _videoController = c;
    // 闭包绑定实例身份：迟到的旧 controller 事件不得读取/修改全局状态
    final closure = () => _onVideoListener(c);
    _videoListenerClosure = closure;
    c.addListener(closure);

    // 起播超时：
    // - 普通频道按用户设置（默认 5 秒，超时自动切下一个源）
    // - 投屏只有一个地址且没有备用源，HLS 跨网慢时给 45 秒，
    //   其它流 15 秒（与投屏重试逻辑配合）
    final rawUrl = channel.streamUrls[_sourceIndex].toLowerCase();
    final isHls = rawUrl.contains('.m3u8') || rawUrl.contains('.m3u');
    final Duration initTimeout;
    if (_isCasting) {
      initTimeout =
          isHls ? const Duration(seconds: 45) : const Duration(seconds: 15);
    } else {
      initTimeout =
          Duration(seconds: _settings.sourceTimeoutSeconds.clamp(3, 60));
    }

    // 代际已过期：静默移除监听并丢弃结果（controller 已被新代 dispose）
    void discardLate(String why) {
      try {
        c.removeListener(closure);
      } catch (_) {}
      if (_isCasting) CastLog.write('cast init late result discarded: $why');
    }

    try {
      // 加超时：流地址失效或后端不支持时显示"播放失败"，避免永远转圈
      await c.initialize().timeout(initTimeout);
      if (gen != _playGeneration) {
        discardLate('stale generation $gen');
        return;
      }
      await c.setLooping(false);
      await c.play();
      await WakelockPlus.enable();

      _state = PlayerState.playing;
      if (_isCasting) {
        CastLog.write(
            'cast init ok: dur=${c.value.duration.inSeconds}s '
            'size=${c.value.size.width.toInt()}x'
            '${c.value.size.height.toInt()}');
      }
      // 记录当前频道，下次启动时恢复
      await _saveLastChannel();
    } on TimeoutException {
      if (gen != _playGeneration) {
        discardLate('stale generation $gen after timeout');
        return;
      }
      debugPrint('源 ${_sourceIndex + 1}/$sourceCount 初始化超时');
      if (_isCasting) {
        // 投屏首拉偶发"音频已通、视频尺寸迟迟不上报"导致 initialize 超时：
        // 用同一 URL 原地重拉一次，仍失败再走备用源/报错
        if (!_castInitRetried) {
          _castInitRetried = true;
          CastLog.write('cast init timeout 15s, retry same url once');
          await _playCurrentSource();
          return;
        }
        CastLog.write('cast init TIMEOUT after retry');
      }
      // 自动尝试下一个源
      if (hasNextSource) {
        _sourceIndex++;
        await _playCurrentSource();
        return;
      }
      if (_isCasting) {
        // 投屏最终失败：清空 DLNA 媒体状态，发送端轮询会发现无媒体，
        // 不再一直显示"已连接"或等待
        dlnaService.clearCurrentMedia();
      }
      _state = PlayerState.error;
    } catch (e) {
      if (gen != _playGeneration) {
        discardLate('stale generation $gen after error');
        return;
      }
      debugPrint('源 ${_sourceIndex + 1}/$sourceCount 播放失败: $e');
      if (_isCasting) CastLog.write('cast init FAILED: $e');
      // 自动尝试下一个源
      if (hasNextSource) {
        _sourceIndex++;
        await _playCurrentSource();
        return;
      }
      if (_isCasting) {
        dlnaService.clearCurrentMedia();
      }
      _state = PlayerState.error;
    }
    notifyListeners();
  }

  void _onVideoListener(VideoPlayerController self) {
    // 只处理当前 controller 的事件，旧实例的迟到事件一律忽略
    if (!identical(self, _videoController)) return;
    final v = self.value;
    if (v.hasError) {
      if (_isCasting) {
        CastLog.write('cast playback error: ${v.errorDescription}');
        // 投屏只有一个源，出错基本意味着流真的断了（直播间关播/CDN 掐流）。
        // 直接切回投屏前频道，比停在 error 等用户手动操作体验好。
        stopCastAndRestore();
        return;
      }
      // 播放中途出错且有备用源时自动切换
      if (hasNextSource) {
        nextSource();
        return;
      }
      _state = PlayerState.error;
      notifyListeners();
      return;
    }
    // 投屏点播内容正常播完：状态切到 ended（DLNA 上报 STOPPED），
    // 发送端据此知道视频结束。上报后等 5 秒，发送端若没主动 Stop/换片，
    // 就自动切回投屏前频道，避免停在最后一帧等用户手动断开。
    if (_isCasting &&
        v.isCompleted &&
        _state == PlayerState.playing) {
      CastLog.write('cast stream completed (end of media)');
      _state = PlayerState.ended;
      notifyListeners();
      _castEndedTimer?.cancel();
      _castEndedTimer = Timer(const Duration(seconds: 5), () {
        _castEndedTimer = null;
        if (_isCasting && _state == PlayerState.ended) {
          CastLog.write('cast ended 5s without sender Stop, auto-restore');
          stopCastAndRestore();
        }
      });
    }
  }

  /// 播放/暂停切换
  Future<void> togglePlayPause() async {
    // 网页频道：通过 JS 控制页面内主 <video>（含同源 iframe）
    if (_webPageActive) {
      final eval = _webEval;
      if (eval == null) return;
      try {
        final r = await eval(_webToggleJs);
        // '1' = 切换后已暂停，'0' = 播放中，'2' = 无可见视频（忽略）
        final s = r?.toString();
        if (s == '0' || s == '1') setWebPlaying(s == '0');
      } catch (_) {}
      return;
    }
    if (_videoController == null || !_videoController!.value.isInitialized) {
      return;
    }
    if (_videoController!.value.isPlaying) {
      await _videoController!.pause();
      _state = PlayerState.paused;
    } else {
      await _videoController!.play();
      _state = PlayerState.playing;
    }
    notifyListeners();
  }

  /// 设置音量 (0.0 - 1.0)
  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    // 音量被外部调大时自动解除静音标记
    if (_volume > 0.01) _isMuted = false;
    if (_webPageActive) {
      // 网页频道：只写页面 video 音量。系统音量与 WebView2 子进程
      // 音频叠加会造成双重衰减；且不动系统音量，不影响其它程序
      _applyWebVolume();
    } else {
      try {
        await VolumeController.instance.setVolume(_volume);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 把当前音量/静音状态写入页面内所有 video（递归同源 iframe）
  void _applyWebVolume() {
    final eval = _webEval;
    if (eval == null) return;
    final v = _volume.toStringAsFixed(3);
    final m = _volume <= 0.01 ? 'true' : 'false';
    eval('(function(){window.__omVol=$v;'
        'function av(root){var out=Array.prototype.slice.call('
        'root.querySelectorAll("video"));var f=root.querySelectorAll("iframe");'
        'for(var i=0;i<f.length;i++){try{var d=f[i].contentDocument;'
        'if(d)out=out.concat(av(d));}catch(e){}}return out;}'
        'var vs=av(document);for(var i=0;i<vs.length;i++){'
        'try{vs[i].volume=$v;vs[i].muted=$m;}catch(e){}}})();');
  }

  /// 静音/恢复（M 键）
  Future<void> toggleMute() async {
    if (_isMuted) {
      _isMuted = false;
      // 恢复到静音前的音量；之前音量接近 0 则恢复默认
      final restore = _volumeBeforeMute <= 0.01 ? 0.8 : _volumeBeforeMute;
      await setVolume(restore);
    } else {
      _volumeBeforeMute = _volume;
      _isMuted = true;
      await setVolume(0.0);
    }
    notifyListeners();
  }

  /// 设置指定静音状态（DLNA 发送端调用，与当前状态相同则不动作）
  Future<void> setMuted(bool muted) async {
    if (_isMuted == muted) return;
    await toggleMute();
  }

  /// 设置亮度 (0.0 - 1.0)
  Future<void> setBrightness(double value) async {
    _brightness = value.clamp(0.0, 1.0);
    try {
      await ScreenBrightness.instance
          .setApplicationScreenBrightness(_brightness);
    } catch (_) {}
    // 网页频道：WebView2 原生 HWND 不受系统亮度影响，用 CSS filter 调光
    if (_webPageActive) _applyWebBrightness();
    notifyListeners();
  }

  /// 网页频道：把亮度写入所有 video 的 CSS filter
  void _applyWebBrightness() {
    final eval = _webEval;
    if (eval == null) return;
    final b = _brightness.toStringAsFixed(3);
    eval('(function(){function av(root){var out=Array.prototype.slice.call('
        'root.querySelectorAll("video"));var f=root.querySelectorAll("iframe");'
        'for(var i=0;i<f.length;i++){try{var d=f[i].contentDocument;'
        'if(d)out=out.concat(av(d));}catch(e){}}return out;}'
        'var vs=av(document);for(var i=0;i<vs.length;i++){'
        'try{vs[i].style.filter="brightness(" + $b + ")";}catch(e){}}})();');
  }

  /// 调节音量增量
  Future<void> adjustVolume(double delta) async {
    await setVolume(_volume + delta * _settings.gestureSensitivity);
  }

  /// 调节亮度增量
  Future<void> adjustBrightness(double delta) async {
    await setBrightness(_brightness + delta * _settings.gestureSensitivity);
  }

  /// 切换全屏（仅桌面端）
  Future<void> toggleFullscreen() async {
    if (!isDesktop) return;
    _isFullscreen = !_isFullscreen;
    await windowManager.setFullScreen(_isFullscreen);
    await _applyAlwaysOnTop();
    if (!_isFullscreen) {
      // 退出全屏后恢复隐藏式标题栏（与启动默认一致）
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
    notifyListeners();
  }

  /// 若当前处于全屏则退出全屏（用于返回键/ESC）
  Future<bool> exitFullscreenIfNeeded() async {
    if (!_isFullscreen) return false;
    _isFullscreen = false;
    await windowManager.setFullScreen(false);
    await _applyAlwaysOnTop();
    // 退出全屏后恢复隐藏式标题栏（与启动默认一致）
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    notifyListeners();
    return true;
  }

  // ==================== 设置持久化 ====================

  static const _kAutoPlayNext = 'settings_auto_play_next';
  static const _kSensitivity = 'settings_sensitivity';
  static const _kAutoHide = 'settings_auto_hide';
  static const _kLaunchAtStartup = 'settings_launch_at_startup';
  static const _kStartFullscreen = 'settings_start_fullscreen';
  static const _kShowClock = 'settings_show_clock';
  static const _kAlwaysOnTop = 'settings_always_on_top';
  static const _kDlnaEnabled = 'settings_dlna_enabled';
  static const _kDefaultVolume = 'settings_default_volume';
  static const _kDefaultBrightness = 'settings_default_brightness';
  static const _kSourceTimeout = 'settings_source_timeout_seconds';
  static const _kBufferSeconds = 'settings_buffer_seconds';
  static const _kUiScale = 'settings_ui_scale';
  static const _kUiScaleAuto = 'settings_ui_scale_auto';
  static const _kRemoteAdmin = 'settings_remote_admin';

  Future<void> _loadSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      _settings = PlayerSettings(
        autoPlayNext: p.getBool(_kAutoPlayNext) ?? true,
        gestureSensitivity: p.getDouble(_kSensitivity) ?? 1.0,
        autoHideDelay: p.getInt(_kAutoHide) ?? 3000,
        launchAtStartup: p.getBool(_kLaunchAtStartup) ?? false,
        startFullscreen: p.getBool(_kStartFullscreen) ?? false,
        showClock: p.getBool(_kShowClock) ?? false,
        // 置顶默认开：避免窗口失焦后快捷键失灵
        alwaysOnTop: p.getBool(_kAlwaysOnTop) ?? true,
        dlnaEnabled: p.getBool(_kDlnaEnabled) ?? true,
        defaultVolume: p.getDouble(_kDefaultVolume) ?? 0.8,
        defaultBrightness: p.getDouble(_kDefaultBrightness) ?? 0.8,
        sourceTimeoutSeconds: p.getInt(_kSourceTimeout) ?? 5,
        bufferSeconds: p.getInt(_kBufferSeconds) ?? 5,
        uiScale: p.getDouble(_kUiScale) ?? 1.0,
        uiScaleAuto: p.getBool(_kUiScaleAuto) ?? true,
        remoteAdminEnabled: p.getBool(_kRemoteAdmin) ?? true,
      );
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAutoPlayNext, _settings.autoPlayNext);
      await p.setDouble(_kSensitivity, _settings.gestureSensitivity);
      await p.setInt(_kAutoHide, _settings.autoHideDelay);
      await p.setBool(_kLaunchAtStartup, _settings.launchAtStartup);
      await p.setBool(_kStartFullscreen, _settings.startFullscreen);
      await p.setBool(_kShowClock, _settings.showClock);
      await p.setBool(_kAlwaysOnTop, _settings.alwaysOnTop);
      await p.setBool(_kDlnaEnabled, _settings.dlnaEnabled);
      await p.setDouble(_kDefaultVolume, _settings.defaultVolume);
      await p.setDouble(_kDefaultBrightness, _settings.defaultBrightness);
      await p.setInt(_kSourceTimeout, _settings.sourceTimeoutSeconds);
      await p.setInt(_kBufferSeconds, _settings.bufferSeconds);
      await p.setDouble(_kUiScale, _settings.uiScale);
      await p.setBool(_kUiScaleAuto, _settings.uiScaleAuto);
      await p.setBool(_kRemoteAdmin, _settings.remoteAdminEnabled);
    } catch (_) {}
  }

  /// 启动时进入全屏（仅在程序启动时由播放器界面调用一次）。
  /// 必须等窗口与 Flutter 首帧布局稳定后再延迟执行，否则在窗口显示
  /// 瞬间切全屏会出现白屏方块+黑边、视频纹理不渲染（只有声音）。
  /// 直接读持久化值，避免与 _loadSettings() 的异步加载竞态。
  Future<void> applyStartupFullscreen() async {
    if (!isDesktop) return;
    try {
      final p = await SharedPreferences.getInstance();
      final want = p.getBool(_kStartFullscreen) ?? false;
      if (!want) {
        _isFullscreen = false;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final already = await windowManager.isFullScreen();
      if (!already) {
        await windowManager.setFullScreen(true);
      }
      _isFullscreen = true;
      await _applyAlwaysOnTop();
      notifyListeners();
    } catch (_) {}
  }

  /// 更新设置并持久化（开机启动项会同步到系统）
  void updateSettings(PlayerSettings settings) {
    final clockChanged = settings.showClock != _settings.showClock;
    if (clockChanged) _logVideoTexture('showClock->${settings.showClock}');
    final launchChanged = settings.launchAtStartup != _settings.launchAtStartup;
    final topChanged = settings.alwaysOnTop != _settings.alwaysOnTop;
    final dlnaChanged = settings.dlnaEnabled != _settings.dlnaEnabled;
    final remoteAdminChanged =
        settings.remoteAdminEnabled != _settings.remoteAdminEnabled;
    _settings = settings;
    _saveSettings();
    if (launchChanged && isDesktop) {
      setAutoLaunchEnabled(settings.launchAtStartup);
    }
    if (topChanged && isDesktop) {
      _applyAlwaysOnTop();
    }
    if (dlnaChanged) {
      if (settings.dlnaEnabled) {
        _startDlna();
      } else {
        _stopDlna();
      }
    }
    if (remoteAdminChanged) {
      if (settings.remoteAdminEnabled) {
        _startRemoteAdmin();
      } else {
        _stopRemoteAdmin();
      }
    }
    notifyListeners();
    if (clockChanged) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _logVideoTexture('postframe showClock'));
    }
  }

  /// 诊断：记录当前视频纹理关键状态（仅写文件日志，无界面探针）
  void _logVideoTexture(String tag) {
    try {
      final vc = _videoController;
      CastLog.write(
          '$tag state=$_state playing=${vc?.value.isPlaying} init=${vc?.value.isInitialized} size=${vc?.value.size}');
    } catch (e) {
      CastLog.write('$tag texture log failed: $e');
    }
  }

  /// 应用窗口置顶设置（全屏时强制置顶，退出全屏后按设置恢复）
  Future<void> _applyAlwaysOnTop() async {
    if (!isDesktop) return;
    try {
      await windowManager
          .setAlwaysOnTop(_isFullscreen ? true : _settings.alwaysOnTop);
    } catch (_) {}
  }

  // ==================== EPG & 节目信息 ====================

  /// 获取当前频道的 EPG（无真实数据时返回空，不使用模拟数据）
  List<EpgProgram> getCurrentEpg() {
    if (_currentChannel == null) return [];
    return sourceManager.getProgramsForChannel(_currentChannel!);
  }

  /// 当前正在播放的节目
  EpgProgram? get currentProgram {
    final now = DateTime.now();
    for (final p in getCurrentEpg()) {
      if (now.isAfter(p.startTime) && now.isBefore(p.endTime)) return p;
    }
    return null;
  }

  /// 即将播放的下一个节目
  EpgProgram? get nextProgram {
    final now = DateTime.now();
    for (final p in getCurrentEpg()) {
      if (p.startTime.isAfter(now)) return p;
    }
    return null;
  }

  /// 当前频道台标（M3U tvg-logo 或 EPG icon），无则空串
  String get currentLogo =>
      _currentChannel == null ? '' : sourceManager.getLogoForChannel(_currentChannel!);

  /// 视频分辨率文字，如 "1280 × 720"
  String get resolutionText {
    final vc = _videoController;
    if (vc == null || !vc.value.isInitialized) return '';
    final w = vc.value.size.width.round();
    final h = vc.value.size.height.round();
    if (w <= 0 || h <= 0) return '';
    return '$w × $h';
  }

  /// fvp 对直播流上报的时长极大（double.maxFinite 微秒 ≈ 9.2e18 秒），
  /// 远超任何真实点播。用"超过 1 天"判定，避免在 web 下使用无法被 JS
  /// 精确表示的大整数字面量导致编译失败。
  static bool _isLiveDuration(Duration d) => d.inSeconds > 86400;

  /// 是否为可拖动进度的点播（非直播流）
  bool get isSeekable {
    final vc = _videoController;
    if (vc == null || !vc.value.isInitialized) return false;
    final d = vc.value.duration;
    // 直播（时长极大）或未知（时长<=0）一律不可拖动
    if (d <= Duration.zero || _isLiveDuration(d)) return false;
    // DLNA 投屏推送的是独立媒体文件：只要时长已知且有限就显示进度条。
    // 视频号/腾讯视频的 stodownload 链接没有文件后缀，旧逻辑用">10 分钟"兜底，
    // 导致几分钟的短视频不显示进度条
    if (_isCasting) return true;
    final raw = _currentChannel?.streamUrls[_sourceIndex] ?? '';
    final path = raw.toLowerCase().split('?').first;
    if (path.startsWith('rtmp') || path.startsWith('rtsp')) return false;
    if (RegExp(r'\.(mp4|mkv|avi|mov|m4v|webm|flv)$').hasMatch(path)) {
      return true;
    }
    // HLS/TS 通常是直播；时长超过 10 分钟的视为点播
    if (path.endsWith('.m3u8') ||
        path.endsWith('.m3u') ||
        path.endsWith('.ts')) {
      return d.inSeconds > 600;
    }
    return d.inSeconds > 600;
  }

  Duration get position => _videoController?.value.position ?? Duration.zero;
  Duration get duration {
    final d = _videoController?.value.duration ?? Duration.zero;
    // 对 UI 隐藏 fvp 直播标记/未知时长，避免 Slider 拿到天文数字时长
    return (d <= Duration.zero || _isLiveDuration(d)) ? Duration.zero : d;
  }

  Future<void> seekTo(Duration position) async {
    // 直播/时长未知的投屏流不支持 seek：部分发送端（微信视频号等）会
    // 周期性下发 Seek 做进度同步，对 HTTP-FLV/HLS 直播执行 seek 会把
    // 播放内核挂起（画面永久卡死），直接忽略
    final rawDur = _videoController?.value.duration ?? Duration.zero;
    if (_isCasting &&
        (rawDur <= Duration.zero || _isLiveDuration(rawDur))) {
      CastLog.write('ignore Seek on live cast: $position');
      return;
    }
    await _videoController?.seekTo(position);
    notifyListeners();
  }

  /// 投屏卡顿看门狗（500ms 一次）。
  ///
  /// 整场投屏【只重建一次】（[_castReinitDone] 统一守门，所有路径共用）：
  /// - 未重建：位置 12 秒不推进先 play() 轻推，25 秒仍不动则重建；
  ///   buffering 持续 30 秒则重建；有声无画 8 秒则重建
  /// - 已重建：再卡/再缓冲 20 秒即判定流不可恢复，断开并恢复投屏前频道
  /// - 每秒采样一行状态到诊断日志
  void _checkCastStall() {
    if (!_isCasting) return;
    // 「恢复投屏前频道」的 800ms 延迟已在途时不再做任何检测/触发，
    // 否则重复调用会把恢复 timer 无限重置（表现为几十秒无法真正断开）
    if (_castRestoreTimer != null) return;
    final vc = _videoController;
    if (vc == null) return;
    final now = DateTime.now();
    final v = vc.value;

    // initialize 尚未完成（典型：音频已通但视频尺寸迟迟不上报）：
    // 每秒记录一行，便于定位"有声无画/重试"
    if (!v.isInitialized) {
      if (_lastCastTickAt == null ||
          now.difference(_lastCastTickAt!).inMilliseconds >= 1000) {
        _lastCastTickAt = now;
        CastLog.write(
            'cast tick pre-init err=${v.hasError} '
            'size=${v.size.width.toInt()}x${v.size.height.toInt()} '
            'buf=${v.isBuffering} play=${v.isPlaying} state=$_state');
      }
      return;
    }

    final posMs = v.position.inMilliseconds;
    final isBuf = v.isBuffering;
    final isPlay = v.isPlaying;
    final done = v.isCompleted;
    final durSec = v.duration.inSeconds;
    final vw = v.size.width.toInt();
    final vh = v.size.height.toInt();
    final noVideo = vw <= 0 || vh <= 0;

    // buffering 沿变化记录
    if (isBuf != _wasBuffering) {
      CastLog.write(isBuf
          ? 'cast buffering START at ${(posMs / 1000).toStringAsFixed(1)}s'
          : 'cast buffering END at ${(posMs / 1000).toStringAsFixed(1)}s');
      _wasBuffering = isBuf;
      _bufferingSince = isBuf ? now : null;
    } else if (isBuf) {
      _bufferingSince ??= now;
    }

    // 每秒采样：位置/缓冲/播放/结束标志/视频尺寸
    if (_lastCastTickAt == null ||
        now.difference(_lastCastTickAt!).inMilliseconds >= 1000) {
      _lastCastTickAt = now;
      CastLog.write(
          'cast tick pos=${(posMs / 1000).toStringAsFixed(1)}/${durSec}s '
          'buf=$isBuf play=$isPlay done=$done size=${vw}x$vh state=$_state');
    }

    // buffering：未重建持续 30 秒→重建；已重建再持续 20 秒→放弃。
    // 长视频（视频号 1 小时等）正常网络缓冲可能持续 10~20 秒，超时不能太短
    if (isBuf && _bufferingSince != null) {
      final bufSecs = now.difference(_bufferingSince!).inSeconds;
      if (!_castReinitDone && bufSecs >= 30) {
        _triggerCastRecovery('buffering >30s');
        return;
      }
      if (_castReinitDone && bufSecs >= 20) {
        CastLog.write(
            'cast buffering persists after recovery (${bufSecs}s), auto-restore');
        stopCastAndRestore();
        return;
      }
    }

    if (_state != PlayerState.playing) return;
    // 正在缓冲时不判 stall：缓冲时位置本就不推进，已有上面的缓冲超时处理
    if (isBuf) return;

    // 有声无画：位置时钟照走但视频尺寸长时间为 0
    if (noVideo) {
      _noVideoSince ??= now;
      final nvSecs = now.difference(_noVideoSince!).inSeconds;
      if (!_castReinitDone && nvSecs >= 8) {
        _triggerCastRecovery('audio-only (size 0) >8s');
      } else if (_castReinitDone && nvSecs >= 15) {
        CastLog.write('cast audio-only persists after recovery, auto-restore');
        stopCastAndRestore();
      }
    } else {
      _noVideoSince = null;
    }

    // stall：位置不推进（非缓冲）
    if (posMs != _watchPosMs) {
      _watchPosMs = posMs;
      _watchAdvanceAt = now;
      _stallNudged = false;
      return;
    }
    _watchAdvanceAt ??= now;
    final stalledMs = now.difference(_watchAdvanceAt!).inMilliseconds;
    if (!_castReinitDone) {
      if (!_stallNudged && stalledMs >= 12000) {
        _stallNudged = true;
        CastLog.write('cast stall detected (${stalledMs}ms), nudge play()');
        vc.play().catchError((_) {});
      } else if (_stallNudged && stalledMs >= 25000) {
        _triggerCastRecovery('stall >25s');
      }
    } else if (stalledMs >= 20000) {
      // 重建后观察期位置仍不推进：流真断了（如直播间关播）
      CastLog.write('cast stall persists after recovery, auto-restore');
      stopCastAndRestore();
    }
  }

  /// 触发投屏自愈重建（整场投屏只允许一次）
  void _triggerCastRecovery(String reason) {
    if (_castReinitDone) return;
    _castReinitDone = true;
    CastLog.write('cast recovery triggered: $reason');
    _recoverCastPlayback();
  }

  /// 投屏流卡死的最终自愈：销毁内核、用同一 URL 重新拉流。
  /// 点播等内核 ready 后从上次位置续播，直播从头缓冲。
  Future<void> _recoverCastPlayback() async {
    final ch = _currentChannel;
    if (ch == null) return;
    final savedPos = _videoController?.value.position ?? Duration.zero;
    final isLive = duration <= Duration.zero;
    CastLog.write(
        'cast recovery: re-init player (live=$isLive, pos=$savedPos)');
    await _playCurrentSource();
    if (!isLive && savedPos > const Duration(seconds: 2)) {
      // 等内核真正开始播放再 seek：
      // 仅 isInitialized && !isBuffering 不够——init 完成后有极短的
      // 非缓冲窗口，此时 seek 会挂死内核（新流在断点处永久缓冲）。
      // 要求位置已实际推进（>0.3s）且在播放中，最多等 10 秒。
      var ready = false;
      for (var i = 0; i < 20; i++) {
        final nv = _videoController?.value;
        if (nv != null &&
            nv.isInitialized &&
            !nv.isBuffering &&
            nv.isPlaying &&
            nv.position.inMilliseconds > 300) {
          ready = true;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (ready) {
        try {
          await _videoController?.seekTo(savedPos);
        } catch (_) {}
      } else {
        // 10 秒都没正常起播：宁可从头播放，也不 seek 进可能挂死的断点
        CastLog.write('cast recovery: not ready, seek skipped');
      }
    }
    // 重置观察计时，给新流一个干净的开始（不动 _castReinitDone）。
    // 否则 _watchAdvanceAt/_bufferingSince 仍是重建前的旧时间，
    // 新流正常缓冲会被立即误判
    _watchPosMs = -1;
    _watchAdvanceAt = null;
    _stallNudged = false;
    _bufferingSince = null;
    _wasBuffering = false;
    _noVideoSince = null;
  }

  /// 获取当前播放节目信息
  NowPlayingInfo getNowPlayingInfo() {
    if (_currentChannel == null) return NowPlayingInfo.empty;
    final cur = currentProgram;
    final next = nextProgram;
    return NowPlayingInfo(
      channelName: _currentChannel!.name,
      programTitle: cur?.title ?? '',
      nextProgramTitle: next?.title,
      programStartTime: cur?.startTime,
      programEndTime: cur?.endTime,
    );
  }

  // ==================== 预约 ====================

  /// 切换节目预约状态
  Future<bool> toggleReservation(EpgProgram program) async {
    // 找到对应频道，记录：时间、节目名、频道名、播放地址（全部备用源）、
    // 台标、EPG 标识。到点后直接用记录的地址播放，避免按名称反查跳错台。
    // 注意：预约只能用「精确匹配」的频道，匹配不到时以当前频道兜底
    // （EPG 面板展示的就是当前频道的节目单），绝不能用名称模糊匹配，
    // 否则像 "CCTV" 这样的短名会错误命中列表里第一个 CCTV 频道。
    final channel = _findChannelExact(program) ?? _currentChannel;
    final r = ProgramReservation(
      id: 'res_${program.channelId}_${program.startTime.millisecondsSinceEpoch}',
      channelId: channel?.id ?? program.channelId,
      channelName: channel?.name ?? '',
      programTitle: program.title,
      startTime: program.startTime,
      endTime: program.endTime,
      autoSwitch: true,
      autoRecord: false,
      createdAt: DateTime.now(),
      streamUrls: channel?.streamUrls ?? const [],
      logoUrl: channel?.logoUrl ?? '',
      tvgId: channel?.tvgId ?? '',
      tvgName: channel?.tvgName ?? program.channelId,
    );
    final result = await reservationManager.toggleReservation(r);
    notifyListeners();
    return result;
  }

  /// 根据 EPG 节目反查对应频道（tvgId 精确匹配，其次名称模糊匹配）
  Channel? findChannelForProgram(EpgProgram program) {
    final exact = _findChannelExact(program);
    if (exact != null) return exact;
    // 精确匹配不到时才做名称模糊匹配（供点击节目条目播放等
    // 容错场景使用；预约存地址不可用这条路径，以免存错台）
    final lowerId = program.channelId.toLowerCase();
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        final name = ch.name.toLowerCase();
        if (name.contains(lowerId) || lowerId.contains(name)) return ch;
      }
    }
    return null;
  }

  /// 仅用精确条件匹配频道：tvgId → tvgName → 规范化后的频道名。
  /// 用于预约等「不允许匹配错误」的场景。
  Channel? _findChannelExact(EpgProgram program) {
    final lowerId = program.channelId.toLowerCase();
    // 1) tvg-id 精确匹配
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        if (ch.tvgId.isNotEmpty && ch.tvgId == program.channelId) return ch;
      }
    }
    // 2) tvg-name 精确匹配
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        if (ch.tvgName.isNotEmpty &&
            ch.tvgName.toLowerCase() == lowerId) {
          return ch;
        }
      }
    }
    // 3) 频道名规范化后精确匹配（忽略大小写/空格/连字符差异，
    //    如 CCTV-1 / cctv1 / "CCTV 1"）
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');
    final target = norm(program.channelId);
    if (target.isNotEmpty) {
      for (final cat in _categories) {
        for (final ch in cat.channels) {
          if (norm(ch.name) == target) return ch;
        }
      }
    }
    return null;
  }

  /// 检查节目是否已预约（同样只用精确匹配，避免状态显示到别的台）
  bool isProgramReserved(EpgProgram program) {
    final channel = _findChannelExact(program);
    final cid = channel?.id ?? program.channelId;
    return reservationManager.isReserved(cid, program.startTime) ||
        reservationManager.isReserved(
            program.channelId, program.startTime);
  }

  // ==================== 录制与截图（fvp/MDK 原生，桌面端） ====================

  /// 开始录制当前画面到固定文件夹，返回是否成功。
  /// 普通频道走 fvp/MDK 原生录制；网页频道用 MediaRecorder 录制
  /// 播放中的 <video>（captureStream），分块经 JS bridge 落盘为 .webm。
  Future<bool> startRecording() async {
    if (_webPageActive) return _startWebRecording();
    final vc = _videoController;
    if (_currentChannel == null || vc == null || !vc.value.isInitialized ||
        !isDesktop || _isRecording) {
      return false;
    }
    try {
      _recordPath =
          await captureService.buildFilePath('recordings', _currentChannel!.name, 'mp4');
      fvpRecord(vc, to: _recordPath);
      _isRecording = true;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = '录制启动失败: $e';
      _isRecording = false;
      notifyListeners();
      return false;
    }
  }

  /// 停止录制，返回文件路径
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    if (_webPageActive) return _stopWebRecording();
    final vc = _videoController;
    try {
      if (vc != null) fvpRecord(vc, to: null);
      // 给编码器一点时间刷新文件尾
      await Future.delayed(const Duration(milliseconds: 800));
    } catch (_) {}
    final path = _recordPath;
    _isRecording = false;
    _recordPath = null;
    notifyListeners();
    return path;
  }

  // ---- 网页频道录制（MediaRecorder） ----

  /// 开始网页录制 JS：捕获正在播放的 video 流并启动 MediaRecorder。
  /// 分块（base64）经 omRecChunk 回传，结束经 omRecEnd 通知。
  static const _webRecStartJs = r'''
(function(){
  try {
    if (window.__omRec) return 'busy';
    function allVideos(root){
      var out = Array.prototype.slice.call(root.querySelectorAll('video'));
      var frames = root.querySelectorAll('iframe');
      for (var i=0;i<frames.length;i++){
        try { var d = frames[i].contentDocument;
              if (d) out = out.concat(allVideos(d)); } catch(e) {}
      }
      return out;
    }
    var vs = allVideos(document);
    // 录制目标 = 主视频（可见面积最大）；优先选在播的，隐藏预览/
    // 广告播放器不参与，避免录到错误画面
    function areaOf(v){
      try {
        var r = v.getBoundingClientRect();
        return (r.width >= 80 && r.height >= 60) ? r.width * r.height : 0;
      } catch(e) { return 0; }
    }
    var target = null, bestA = 0;
    for (var i=0;i<vs.length;i++){
      if (vs[i].paused || vs[i].ended || vs[i].readyState < 2) continue;
      var a = areaOf(vs[i]);
      if (a > bestA) { bestA = a; target = vs[i]; }
    }
    if (!target) {
      bestA = 0;
      for (var j=0;j<vs.length;j++){
        var a2 = areaOf(vs[j]);
        if (a2 > bestA) { bestA = a2; target = vs[j]; }
      }
    }
    if (!target) return 'novideo';
    var capture = target.captureStream || target.mozCaptureStream;
    if (!capture) return 'nocapture';
    var stream = capture.call(target);
    var mime = '';
    // 优先 mp4（与 fvp 原生录制格式一致），WebView2/Edge 支持 H.264
    var cands = [
      'video/mp4;codecs=h264,aac',
      'video/mp4;codecs=avc1.42E01E,mp4a.40.2',
      'video/mp4',
      'video/webm;codecs=vp9,opus',
      'video/webm;codecs=vp8,opus',
      'video/webm'
    ];
    for (var m=0;m<cands.length;m++){
      try { if (MediaRecorder.isTypeSupported(cands[m])) { mime = cands[m]; break; } } catch(e){}
    }
    var rec = mime ? new MediaRecorder(stream, {mimeType: mime})
                   : new MediaRecorder(stream);
    window.__omRec = rec;
    window.__omRecChain = Promise.resolve();
    rec.ondataavailable = function(e){
      if (!e.data || !e.data.size) return;
      var blob = e.data;
      window.__omRecChain = window.__omRecChain.then(function(){
        return new Promise(function(resolve){
          var fr = new FileReader();
          fr.onload = function(){
            try {
              var s = (fr.result || '').toString();
              var i = s.indexOf('base64,');
              if (i >= 0) {
                window.flutter_inappwebview.callHandler('omRecChunk', s.substring(i+7));
              }
            } catch(err) {}
            resolve();
          };
          fr.onerror = function(){ resolve(); };
          fr.readAsDataURL(blob);
        });
      });
    };
    rec.start(1000);
    var ext = (mime && mime.indexOf('mp4') >= 0) ? 'mp4' : 'webm';
    return 'ok:' + ext;
  } catch(e) { return 'err'; }
})();
''';

  /// 停止网页录制 JS：停止 MediaRecorder，所有分块回传完成后
  /// 发 omRecEnd 通知 Dart 收尾。
  static const _webRecStopJs = r'''
(function(){
  try {
    var rec = window.__omRec;
    if (!rec) return 'none';
    window.__omRec = null;
    rec.onstop = function(){
      var chain = window.__omRecChain || Promise.resolve();
      chain.then(function(){
        try { window.flutter_inappwebview.callHandler('omRecEnd', 1); } catch(e) {}
      });
    };
    rec.stop();
    return 'ok';
  } catch(e) {
    try { window.flutter_inappwebview.callHandler('omRecEnd', 1); } catch(_) {}
    return 'err';
  }
})();
''';

  /// 网页录制启动（由 startRecording 在网页频道时调用）
  Future<bool> _startWebRecording() async {
    final eval = _webEval;
    if (eval == null || !isDesktop || _isRecording) return false;
    try {
      _webRecBytes = 0;
      final r = await eval(_webRecStartJs);
      final rs = r?.toString() ?? '';
      if (!rs.startsWith('ok')) {
        _lastError = rs == 'novideo'
            ? '网页中未找到可录制的视频'
            : '网页不支持视频录制';
        return false;
      }
      // JS 返回实际容器格式（mp4 优先，回退 webm）
      final ext = rs.substring(3) == 'mp4' ? 'mp4' : 'webm';
      _recordPath = await captureService.buildFilePath(
          'recordings', _currentChannel?.name ?? 'web', ext);
      _webRecDone = Completer<void>();
      _isRecording = true;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = '网页录制启动失败: $e';
      _recordPath = null;
      return false;
    }
  }

  /// 网页录制停止：通知网页停止 MediaRecorder，等末尾分块全部落盘
  Future<String?> _stopWebRecording() async {
    final eval = _webEval;
    final done = _webRecDone;
    try {
      await eval?.call(_webRecStopJs);
      if (done != null) {
        await done.future.timeout(const Duration(seconds: 5),
            onTimeout: () {});
      }
    } catch (_) {}
    final path = _webRecBytes > 0 ? _recordPath : null;
    _isRecording = false;
    _recordPath = null;
    _webRecDone = null;
    _webRecBytes = 0;
    notifyListeners();
    return path;
  }

  /// JS bridge 回传的录制分块（base64），追加写入录制文件
  Future<void> appendWebRecordingChunk(String b64) async {
    final path = _recordPath;
    if (!_isRecording || path == null || b64.isEmpty) return;
    try {
      final bytes = base64Decode(b64);
      await captureService.appendBytes(path, bytes);
      _webRecBytes += bytes.length;
      notifyListeners();
    } catch (_) {}
  }

  /// JS bridge 通知录制流已结束（最后分块已回传）
  void finishWebRecording() {
    if (_webRecDone != null && !_webRecDone!.isCompleted) {
      _webRecDone!.complete();
    }
  }

  /// 截取当前视频帧保存为 PNG（固定文件夹）。
  /// 网页频道走 WebView 截图桥，返回的就是 PNG 字节，直接落盘。
  Future<String?> takeScreenshot() async {
    if (_webPageActive) {
      final shot = _webScreenshot;
      if (shot == null) return null;
      try {
        final bytes = await shot();
        if (bytes == null || bytes.isEmpty) return null;
        final name = _currentChannel?.name ?? 'web_screenshot';
        final path =
            await captureService.buildFilePath('screenshots', name, 'png');
        await captureService.saveBytes(path, Uint8List.fromList(bytes));
        return path;
      } catch (e) {
        _lastError = '网页截图失败: $e';
        return null;
      }
    }
    final vc = _videoController;
    if (vc == null || !vc.value.isInitialized) return null;
    try {
      final w = vc.value.size.width.round();
      final h = vc.value.size.height.round();
      final rgba = await fvpSnapshot(vc, width: w, height: h);
      if (rgba == null || w == 0 || h == 0) return null;
      final png = await captureService.rgbaToPng(rgba, w, h);
      final name = _currentChannel?.name ?? 'screenshot';
      final path = await captureService.buildFilePath('screenshots', name, 'png');
      await captureService.saveBytes(path, png);
      return path;
    } catch (e) {
      _lastError = '截图失败: $e';
      return null;
    }
  }

  // ==================== 播放列表/EPG 源管理（代理方法） ====================

  Future<void> addPlaylist(PlaylistSource source) async {
    await sourceManager.addPlaylist(source);
    // 首个播放列表自动选中并加载频道，让左侧列表立即可读
    if (sourceManager.currentPlaylistId == null) {
      await selectPlaylist(source.id);
    } else {
      notifyListeners();
    }
  }

  Future<void> removePlaylist(String id) async {
    await sourceManager.removePlaylist(id);
    if (sourceManager.currentPlaylistId == null) {
      _categories = [];
    }
    notifyListeners();
  }

  /// 编辑播放列表（名称/地址/类型）；当前源地址变化时重新加载频道
  Future<void> editPlaylist(PlaylistSource source) async {
    final idx =
        sourceManager.playlists.indexWhere((p) => p.id == source.id);
    final urlChanged =
        idx >= 0 && sourceManager.playlists[idx].url != source.url;
    await sourceManager.updatePlaylist(source);
    if (urlChanged && sourceManager.currentPlaylistId == source.id) {
      await refreshChannels();
    } else {
      notifyListeners();
    }
  }

  Future<void> selectPlaylist(String? id) async {
    await sourceManager.selectPlaylist(id);
    if (id != null) {
      await refreshChannels();
    } else {
      _categories = [];
      notifyListeners();
    }
  }

  Future<void> addEpg(EpgSource source) async {
    await sourceManager.addEpg(source);
    // 首个 EPG 源自动选中并加载节目单
    if (sourceManager.currentEpgId == null) {
      await selectEpg(source.id);
    } else {
      notifyListeners();
    }
  }

  Future<void> removeEpg(String id) async {
    await sourceManager.removeEpg(id);
    notifyListeners();
  }

  /// 编辑 EPG（名称/地址）；当前源地址变化时重新加载节目单
  Future<void> editEpg(EpgSource source) async {
    final idx = sourceManager.epgs.indexWhere((e) => e.id == source.id);
    final urlChanged =
        idx >= 0 && sourceManager.epgs[idx].url != source.url;
    await sourceManager.updateEpg(source);
    if (urlChanged && sourceManager.currentEpgId == source.id) {
      await refreshEpg();
    } else {
      notifyListeners();
    }
  }

  Future<void> selectEpg(String? id) async {
    await sourceManager.selectEpg(id);
    if (id != null) {
      await refreshEpg();
    } else {
      notifyListeners();
    }
  }

  // ==================== NumLock 状态守护（Windows runner 层实现） ====================
  // Flutter Windows 引擎在窗口初始化时会把 NumLock 意外同步为关闭。
  // 该修复必须在原生 runner 的 UI 线程做（Dart FFI 线程没有消息队列，
  // GetKeyState 恒返回 0 会误判并主动翻转，反而把 NumLock 关掉）：
  // CI 构建时由 .github/workflows/build.yml 向 windows/runner/main.cpp
  // 注入「启动保存状态 + 15 秒定时器恢复」代码，见 Patch Windows runner 步骤。

  Future<void> _disposeVideoController() async {
    final c = _videoController;
    if (c != null) {
      final closure = _videoListenerClosure;
      _videoListenerClosure = null;
      _videoController = null;
      if (closure != null) {
        try {
          c.removeListener(closure);
        } catch (_) {}
      }
      try {
        // 播放器卡死时 native dispose 也可能挂起：最多等 3 秒，
        // 超时就放弃该实例，绝不能阻塞后续播放（重试按钮"没反应"的防线）
        await c.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _castRestoreTimer?.cancel();
    _castEndedTimer?.cancel();
    _resetWebRecording();
    if (_isRecording && _videoController != null) {
      fvpRecord(_videoController!, to: null);
    }
    _disposeVideoController();
    WakelockPlus.disable();
    dlnaService.stop();
    remoteAdminService.stop();
    reservationManager.dispose();
    super.dispose();
  }
}
