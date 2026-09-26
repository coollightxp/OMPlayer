/// 播放器设置
class PlayerSettings {
  /// 自动播放下一个频道
  final bool autoPlayNext;

  /// 默认音量 (0.0 - 1.0)
  final double defaultVolume;

  /// 默认亮度 (0.0 - 1.0)
  final double defaultBrightness;

  /// 画中画模式
  final bool pipEnabled;

  /// 视频质量偏好
  final VideoQuality preferredQuality;

  /// 手势灵敏度 (0.5 - 2.0)
  final double gestureSensitivity;

  /// 面板自动隐藏延迟（毫秒）
  final int autoHideDelay;

  /// 开机自启动
  final bool launchAtStartup;

  /// 启动即进入全屏（仅在程序启动时检测一次）
  final bool startFullscreen;

  /// 右上角常驻显示系统时间
  final bool showClock;

  const PlayerSettings({
    this.autoPlayNext = true,
    this.defaultVolume = 0.8,
    this.defaultBrightness = 0.8,
    this.pipEnabled = false,
    this.preferredQuality = VideoQuality.auto,
    this.gestureSensitivity = 1.0,
    this.autoHideDelay = 3000,
    this.launchAtStartup = false,
    this.startFullscreen = false,
    this.showClock = false,
  });

  PlayerSettings copyWith({
    bool? autoPlayNext,
    double? defaultVolume,
    double? defaultBrightness,
    bool? pipEnabled,
    VideoQuality? preferredQuality,
    double? gestureSensitivity,
    int? autoHideDelay,
    bool? launchAtStartup,
    bool? startFullscreen,
    bool? showClock,
  }) {
    return PlayerSettings(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      defaultBrightness: defaultBrightness ?? this.defaultBrightness,
      pipEnabled: pipEnabled ?? this.pipEnabled,
      preferredQuality: preferredQuality ?? this.preferredQuality,
      gestureSensitivity: gestureSensitivity ?? this.gestureSensitivity,
      autoHideDelay: autoHideDelay ?? this.autoHideDelay,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startFullscreen: startFullscreen ?? this.startFullscreen,
      showClock: showClock ?? this.showClock,
    );
  }
}

enum VideoQuality {
  auto('自动'),
  low('标清 480p'),
  medium('高清 720p'),
  high('全高清 1080p'),
  ultra('超清 4K');

  final String label;
  const VideoQuality(this.label);
}
