import 'dart:async';

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

    // 播放中每 500ms 刷新一次（进度条、倒计时等）
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
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

    _initSystemValues();
    notifyListeners();
  }

  /// 预约触发回调 - 自动切换/录制
  void _onReservationTriggered(ProgramReservation r) {
    if (r.autoSwitch) {
      // 找到对应频道并播放
      final channel = _findChannelById(r.channelId);
      if (channel != null) {
        playChannel(channel);
      }
    }
    if (r.autoRecord && isDesktop) {
      final channel = _findChannelById(r.channelId);
      if (channel != null) {
        startRecording();
      }
    }
    notifyListeners();
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

  /// 播放当前频道的当前源；初始化失败时自动尝试下一个源
  /// （与 v1.0.6 验证可用的逻辑保持一致，不做额外的加锁拦截）
  Future<void> _playCurrentSource() async {
    final channel = _currentChannel;
    if (channel == null) return;
    _state = PlayerState.loading;
    notifyListeners();

    await _disposeVideoController();

    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(channel.streamUrls[_sourceIndex]),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      _videoController!.addListener(_onVideoListener);
      // 加超时：流地址失效或后端不支持时显示"播放失败"，避免永远转圈
      await _videoController!.initialize()
          .timeout(const Duration(seconds: 15));
      await _videoController!.setLooping(false);
      await _videoController!.play();
      await WakelockPlus.enable();

      _state = PlayerState.playing;
    } catch (e) {
      debugPrint('源 ${_sourceIndex + 1}/$sourceCount 播放失败: $e');
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

  void _onVideoListener() {
    if (_videoController == null) return;
    if (_videoController!.value.hasError) {
      // 播放中途出错且有备用源时自动切换
      if (hasNextSource) {
        nextSource();
        return;
      }
      _state = PlayerState.error;
      notifyListeners();
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
    try {
      await VolumeController.instance.setVolume(_volume);
    } catch (_) {}
    notifyListeners();
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
    notifyListeners();
  }

  /// 若当前处于全屏则退出全屏（用于返回键/ESC）
  Future<bool> exitFullscreenIfNeeded() async {
    if (!_isFullscreen) return false;
    _isFullscreen = false;
    await windowManager.setFullScreen(false);
    notifyListeners();
    return true;
  }

  /// 启动时由 main 已按设置进入全屏，这里只同步内部标记，
  /// 保证 ESC、双击退出等状态判断正确
  void syncInitialFullscreen() {
    if (isDesktop && _settings.startFullscreen && !_isFullscreen) {
      _isFullscreen = true;
    }
  }

  // ==================== 设置持久化 ====================

  static const _kAutoPlayNext = 'settings_auto_play_next';
  static const _kPip = 'settings_pip';
  static const _kSensitivity = 'settings_sensitivity';
  static const _kAutoHide = 'settings_auto_hide';
  static const _kLaunchAtStartup = 'settings_launch_at_startup';
  static const _kStartFullscreen = 'settings_start_fullscreen';
  static const _kShowClock = 'settings_show_clock';
  static const _kDefaultVolume = 'settings_default_volume';
  static const _kDefaultBrightness = 'settings_default_brightness';

  Future<void> _loadSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      _settings = PlayerSettings(
        autoPlayNext: p.getBool(_kAutoPlayNext) ?? true,
        pipEnabled: p.getBool(_kPip) ?? false,
        gestureSensitivity: p.getDouble(_kSensitivity) ?? 1.0,
        autoHideDelay: p.getInt(_kAutoHide) ?? 3000,
        launchAtStartup: p.getBool(_kLaunchAtStartup) ?? false,
        startFullscreen: p.getBool(_kStartFullscreen) ?? false,
        showClock: p.getBool(_kShowClock) ?? false,
        defaultVolume: p.getDouble(_kDefaultVolume) ?? 0.8,
        defaultBrightness: p.getDouble(_kDefaultBrightness) ?? 0.8,
      );
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAutoPlayNext, _settings.autoPlayNext);
      await p.setBool(_kPip, _settings.pipEnabled);
      await p.setDouble(_kSensitivity, _settings.gestureSensitivity);
      await p.setInt(_kAutoHide, _settings.autoHideDelay);
      await p.setBool(_kLaunchAtStartup, _settings.launchAtStartup);
      await p.setBool(_kStartFullscreen, _settings.startFullscreen);
      await p.setBool(_kShowClock, _settings.showClock);
      await p.setDouble(_kDefaultVolume, _settings.defaultVolume);
      await p.setDouble(_kDefaultBrightness, _settings.defaultBrightness);
    } catch (_) {}
  }

  /// 更新设置并持久化（开机启动项会同步到系统）
  void updateSettings(PlayerSettings settings) {
    final launchChanged = settings.launchAtStartup != _settings.launchAtStartup;
    _settings = settings;
    _saveSettings();
    if (launchChanged && isDesktop) {
      setAutoLaunchEnabled(settings.launchAtStartup);
    }
    notifyListeners();
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

  /// 是否为可拖动进度的点播（非直播流）
  bool get isSeekable {
    final vc = _videoController;
    if (vc == null || !vc.value.isInitialized) return false;
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
      return vc.value.duration.inSeconds > 600;
    }
    return vc.value.duration.inSeconds > 600;
  }

  Duration get position => _videoController?.value.position ?? Duration.zero;
  Duration get duration => _videoController?.value.duration ?? Duration.zero;

  Future<void> seekTo(Duration position) async {
    await _videoController?.seekTo(position);
    notifyListeners();
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
    final r = ProgramReservation(
      id: 'res_${program.channelId}_${program.startTime.millisecondsSinceEpoch}',
      channelId: program.channelId,
      channelName: _currentChannel?.name ?? '',
      programTitle: program.title,
      startTime: program.startTime,
      endTime: program.endTime,
      autoSwitch: true,
      autoRecord: false,
      createdAt: DateTime.now(),
    );
    final result = await reservationManager.toggleReservation(r);
    notifyListeners();
    return result;
  }

  /// 根据 EPG 节目反查对应频道（tvgId 精确匹配，其次名称模糊匹配）
  Channel? findChannelForProgram(EpgProgram program) {
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        if (ch.tvgId.isNotEmpty && ch.tvgId == program.channelId) return ch;
      }
    }
    final lowerId = program.channelId.toLowerCase();
    for (final cat in _categories) {
      for (final ch in cat.channels) {
        if (ch.tvgName.isNotEmpty &&
            ch.tvgName.toLowerCase() == lowerId) return ch;
        final name = ch.name.toLowerCase();
        if (name.contains(lowerId) || lowerId.contains(name)) return ch;
      }
    }
    return null;
  }

  /// 检查节目是否已预约
  bool isProgramReserved(EpgProgram program) {
    return reservationManager.isReserved(program.channelId, program.startTime);
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
    if (_videoController != null) {
      _videoController!.removeListener(_onVideoListener);
      await _videoController!.dispose();
      _videoController = null;
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    if (_isRecording && _videoController != null) {
      fvpRecord(_videoController!, to: null);
    }
    _disposeVideoController();
    WakelockPlus.disable();
    reservationManager.dispose();
    super.dispose();
  }
}
