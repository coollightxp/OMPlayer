import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/epg_source.dart';
import '../models/player_settings.dart';
import '../models/playlist_source.dart';
import '../models/reservation.dart';
import 'media_capture_service.dart';
import 'mock_data_service.dart';
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
  bool get isRecording => captureService.isRecording;
  bool get isDesktop => MediaCaptureService.isDesktop;

  bool get isPlaying => _state == PlayerState.playing;
  bool get isInitialized =>
      _videoController != null && _videoController!.value.isInitialized;

  PlayerController() {
    _init();
  }

  Future<void> _init() async {
    await sourceManager.loadFromPrefs();
    await reservationManager.init(_onReservationTriggered);

    // 如果有选中的播放列表，加载频道
    if (sourceManager.currentPlaylist != null) {
      await refreshChannels();
    } else {
      // 否则使用模拟数据
      _categories = MockDataService.getCategories();
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
        captureService.startRecording(channel.streamUrl, channel.name);
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
      _brightness = await ScreenBrightness().current;
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

  /// 播放指定频道
  Future<void> playChannel(Channel channel) async {
    _currentChannel = channel;
    _state = PlayerState.loading;
    notifyListeners();

    await _disposeVideoController();

    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(channel.streamUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      _videoController!.addListener(_onVideoListener);
      await _videoController!.initialize();
      await _videoController!.setLooping(false);
      await _videoController!.play();
      await WakelockPlus.enable();

      _state = PlayerState.playing;
    } catch (e) {
      debugPrint('播放失败: $e');
      _state = PlayerState.error;
    }
    notifyListeners();
  }

  void _onVideoListener() {
    if (_videoController == null) return;
    if (_videoController!.value.hasError) {
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
      await ScreenBrightness().setScreenBrightness(_brightness);
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

  /// 更新设置
  void updateSettings(PlayerSettings settings) {
    _settings = settings;
    notifyListeners();
  }

  // ==================== EPG & 节目信息 ====================

  /// 获取当前频道的 EPG
  List<EpgProgram> getCurrentEpg() {
    if (_currentChannel == null) return [];
    // 优先使用加载的真实 EPG 数据
    final programs = sourceManager.getProgramsForChannel(_currentChannel!);
    if (programs.isNotEmpty) return programs;
    // 回退到模拟数据
    return MockDataService.getEpgForChannel(_currentChannel!.id);
  }

  /// 获取当前播放节目信息
  NowPlayingInfo getNowPlayingInfo() {
    if (_currentChannel == null) return NowPlayingInfo.empty;
    final epg = getCurrentEpg();
    EpgProgram? current;
    EpgProgram? next;
    final now = DateTime.now();
    for (final p in epg) {
      if (p.isNowPlaying) current = p;
      if (p.startTime.isAfter(now) && next == null) next = p;
    }
    return NowPlayingInfo(
      channelName: _currentChannel!.name,
      programTitle: current?.title ?? '未知节目',
      nextProgramTitle: next?.title,
      programStartTime: current?.startTime,
      programEndTime: current?.endTime,
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

  /// 检查节目是否已预约
  bool isProgramReserved(EpgProgram program) {
    return reservationManager.isReserved(program.channelId, program.startTime);
  }

  // ==================== 录制与截图（桌面端） ====================

  Future<bool> startRecording() async {
    if (_currentChannel == null || !isDesktop) return false;
    try {
      final ok = await captureService.startRecording(
        _currentChannel!.streamUrl,
        _currentChannel!.name,
      );
      notifyListeners();
      return ok;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<String?> stopRecording() async {
    final path = await captureService.stopRecording();
    notifyListeners();
    return path;
  }

  Future<String?> takeScreenshot() async {
    if (_currentChannel == null) return null;
    return captureService.takeScreenshot(_currentChannel!.name);
  }

  // ==================== 播放列表/EPG 源管理（代理方法） ====================

  Future<void> addPlaylist(PlaylistSource source) async {
    await sourceManager.addPlaylist(source);
    notifyListeners();
  }

  Future<void> removePlaylist(String id) async {
    await sourceManager.removePlaylist(id);
    if (sourceManager.currentPlaylistId == null) {
      _categories = MockDataService.getCategories();
    }
    notifyListeners();
  }

  Future<void> selectPlaylist(String? id) async {
    await sourceManager.selectPlaylist(id);
    if (id != null) {
      await refreshChannels();
    } else {
      _categories = MockDataService.getCategories();
      notifyListeners();
    }
  }

  Future<void> addEpg(EpgSource source) async {
    await sourceManager.addEpg(source);
    notifyListeners();
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
    _disposeVideoController();
    WakelockPlus.disable();
    reservationManager.dispose();
    if (captureService.isRecording) {
      captureService.stopRecording();
    }
    super.dispose();
  }
}
