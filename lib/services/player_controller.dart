import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
import 'media_capture_service.dart';
import 'native_capture.dart';
import 'reservation_manager.dart';
import 'source_manager.dart';

/// 播放器状态
enum PlayerState { idle, loading, playing, paused, error, ended }

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

  // 投屏诊断日志路径（设置面板展示给用户反馈问题）
  String _castLogPath = '';
  String get castLogPath => _castLogPath;

  // 投屏卡顿看门狗：状态仍为"播放中"但播放位置长时间不推进时，
  // 说明网络流被静默掐断（常见于 HTTP-FLV/视频号直播），需要自愈
  int _watchPosMs = -1;
  DateTime? _watchAdvanceAt;
  bool _stallNudged = false;
  bool _stallReinitTried = false;

  // 投屏诊断：1 秒一次状态采样 + buffering 持续超时自愈
  DateTime? _lastCastTickAt;
  bool _wasBuffering = false;
  DateTime? _bufferingSince;
  bool _bufferReinitTried = false;

  // 有声无画面看门狗：音频在播但视频尺寸长时间为 0（解码链视频轨没起来）
  DateTime? _noVideoSince;
  bool _noVideoReinitTried = false;
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

  // 录制状态（fvp 原生录制）
  bool _isRecording = false;
  String? _recordPath;

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
  bool get isDesktop => !kIsWeb && MediaCaptureService.isDesktop;
  bool get isFullscreen => _isFullscreen;
  bool get isCasting => _isCasting;
  bool get isMuted => _isMuted;

  bool get isPlaying => _state == PlayerState.playing;
  bool get isInitialized =>
      _videoController != null && _videoController!.value.isInitialized;

  PlayerController() {
    _init();
  }

  Future<void> _init() async {
    await _loadSettings();
    await sourceManager.loadFromPrefs();
    await reservationManager.init(_onReservationTriggered);
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
    _initSystemValues();

    // 频道加载完毕后，恢复上次退出时播放的频道
    await restoreLastChannel();

    notifyListeners();
  }

  // ==================== 上次播放记忆 ====================

  static const _kLastChannel = 'last_channel_v1';

  /// 播放成功后记录当前频道，供下次启动恢复
  Future<void> _saveLastChannel() async {
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
      );
      _sourceIndex =
          srcIdx < target.streamUrls.length ? srcIdx : 0;
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
    _stallReinitTried = false;
    _lastCastTickAt = null;
    _wasBuffering = false;
    _bufferingSince = null;
    _bufferReinitTried = false;
    _noVideoSince = null;
    _noVideoReinitTried = false;
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
    _castEndedTimer?.cancel();
    _castEndedTimer = null;
    _castRestoreTimer?.cancel();
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
    _currentChannel = channel;
    _sourceIndex = 0;
    await _playCurrentSource();
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

    await _disposeVideoController();

    final c = VideoPlayerController.networkUrl(
      Uri.parse(channel.streamUrls[_sourceIndex]),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _videoController = c;
    // 闭包绑定实例身份：迟到的旧 controller 事件不得读取/修改全局状态
    final closure = () => _onVideoListener(c);
    _videoListenerClosure = closure;
    c.addListener(closure);

    // 代际已过期：静默移除监听并丢弃结果（controller 已被新代 dispose）
    void discardLate(String why) {
      try {
        c.removeListener(closure);
      } catch (_) {}
      if (_isCasting) CastLog.write('cast init late result discarded: $why');
    }

    try {
      // 加超时：流地址失效或后端不支持时显示"播放失败"，避免永远转圈
      await c.initialize().timeout(const Duration(seconds: 15));
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
    try {
      await VolumeController.instance.setVolume(_volume);
    } catch (_) {}
    notifyListeners();
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
    notifyListeners();
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
    final launchChanged = settings.launchAtStartup != _settings.launchAtStartup;
    final topChanged = settings.alwaysOnTop != _settings.alwaysOnTop;
    final dlnaChanged = settings.dlnaEnabled != _settings.dlnaEnabled;
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
    notifyListeners();
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

  /// 投屏卡顿看门狗（500ms 一次）：
  /// - 播放中位置超过 12 秒不推进，先尝试 play() 轻推；25 秒仍不动则重新拉流
  /// - isBuffering 持续超过 10 秒（网络断流但未报错）直接重新拉流
  /// - 播放中视频尺寸持续 8 秒为 0（有声无画）重新拉流
  /// - 每秒采样一行状态到诊断日志（含视频尺寸，定位解码层卡死/有声无画）
  void _checkCastStall() {
    if (!_isCasting) return;
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

    // 持续 buffering 超过 10 秒：流已断但内核没报错，干净重建
    if (isBuf &&
        !_bufferReinitTried &&
        _bufferingSince != null &&
        now.difference(_bufferingSince!).inSeconds >= 10) {
      _bufferReinitTried = true;
      CastLog.write('cast buffering >10s, trigger recovery');
      _recoverCastPlayback();
      return;
    }

    if (_state != PlayerState.playing) return;

    // 有声无画：位置时钟照走但视频尺寸长时间为 0，视频解码轨没恢复，
    // 重建一次拉流（整场投屏只重建一次，避免死循环）
    if (noVideo) {
      _noVideoSince ??= now;
      if (!_noVideoReinitTried &&
          now.difference(_noVideoSince!).inSeconds >= 8) {
        _noVideoReinitTried = true;
        CastLog.write('cast audio-only (video size 0) >8s, trigger recovery');
        _recoverCastPlayback();
      }
    } else {
      _noVideoSince = null;
    }

    if (posMs != _watchPosMs) {
      _watchPosMs = posMs;
      _watchAdvanceAt = now;
      _stallNudged = false;
      _stallReinitTried = false;
      return;
    }
    _watchAdvanceAt ??= now;
    final stalledMs = now.difference(_watchAdvanceAt!).inMilliseconds;
    if (!_stallNudged && stalledMs >= 12000) {
      _stallNudged = true;
      CastLog.write('cast stall detected (${stalledMs}ms), nudge play()');
      vc.play().catchError((_) {});
    } else if (_stallNudged &&
        !_stallReinitTried &&
        stalledMs >= 25000) {
      _stallReinitTried = true;
      _recoverCastPlayback();
    } else if (_stallReinitTried && stalledMs >= 40000) {
      // 重建后位置仍不推进（流真断了，如直播间关播），切回投屏前频道
      CastLog.write('cast stall persisted after recovery, auto-restore');
      stopCastAndRestore();
    }
  }

  /// 投屏流卡死的最终自愈：销毁内核、用同一 URL 重新拉流。
  /// 点播从上次位置续播，直播从头缓冲。整场投屏只重建一次，避免死循环。
  Future<void> _recoverCastPlayback() async {
    final ch = _currentChannel;
    if (ch == null) return;
    final savedPos = _videoController?.value.position ?? Duration.zero;
    final isLive = duration <= Duration.zero;
    _noVideoSince = null;
    CastLog.write(
        'cast stall recovery: re-init player (live=$isLive, pos=$savedPos)');
    await _playCurrentSource();
    if (!isLive && savedPos > const Duration(seconds: 2)) {
      try {
        await _videoController?.seekTo(savedPos);
      } catch (_) {}
    }
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

  /// 开始录制当前画面到固定文件夹，返回是否成功
  Future<bool> startRecording() async {
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

  /// 截取当前视频帧保存为 PNG（固定文件夹）
  Future<String?> takeScreenshot() async {
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

  Future<void> selectEpg(String? id) async {
    await sourceManager.selectEpg(id);
    if (id != null) {
      await refreshEpg();
    } else {
      notifyListeners();
    }
  }

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
    if (_isRecording && _videoController != null) {
      fvpRecord(_videoController!, to: null);
    }
    _disposeVideoController();
    WakelockPlus.disable();
    dlnaService.stop();
    reservationManager.dispose();
    super.dispose();
  }
}
