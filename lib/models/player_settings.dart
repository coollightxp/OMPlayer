/// 播放器设置
class PlayerSettings {
  /// 自动播放下一个频道
  final bool autoPlayNext;

  /// 默认音量 (0.0 - 1.0)
  final double defaultVolume;

  /// 默认亮度 (0.0 - 1.0)
  final double defaultBrightness;

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

  /// 窗口置顶（仅桌面端，默认开：保证快捷键焦点不被其它窗口抢走）
  final bool alwaysOnTop;

  /// DLNA 投屏接收服务开关（默认开）
  final bool dlnaEnabled;

  /// 单个播放源起播等待秒数：超时后自动切换下一个源（默认 5 秒，5 秒一档）
  final int sourceTimeoutSeconds;

  /// 界面字体缩放（1.0 = 系统默认；4K/8K 大屏可调到 1.5~3.0）
  final double uiScale;

  /// 局域网 Web 管理服务开关（手机扫码管理直播源/EPG）
  final bool remoteAdminEnabled;

  const PlayerSettings({
    this.autoPlayNext = true,
    this.defaultVolume = 0.8,
    this.defaultBrightness = 0.8,
    this.preferredQuality = VideoQuality.auto,
    this.gestureSensitivity = 1.0,
    this.autoHideDelay = 3000,
    this.launchAtStartup = false,
    this.startFullscreen = false,
    this.showClock = false,
    this.alwaysOnTop = true,
    this.dlnaEnabled = true,
    this.sourceTimeoutSeconds = 5,
    this.uiScale = 1.0,
    this.remoteAdminEnabled = true,
  });

  PlayerSettings copyWith({
    bool? autoPlayNext,
    double? defaultVolume,
    double? defaultBrightness,
    VideoQuality? preferredQuality,
    double? gestureSensitivity,
    int? autoHideDelay,
    bool? launchAtStartup,
    bool? startFullscreen,
    bool? showClock,
    bool? alwaysOnTop,
    bool? dlnaEnabled,
    int? sourceTimeoutSeconds,
    double? uiScale,
    bool? remoteAdminEnabled,
  }) {
    return PlayerSettings(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      defaultBrightness: defaultBrightness ?? this.defaultBrightness,
      preferredQuality: preferredQuality ?? this.preferredQuality,
      gestureSensitivity: gestureSensitivity ?? this.gestureSensitivity,
      autoHideDelay: autoHideDelay ?? this.autoHideDelay,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startFullscreen: startFullscreen ?? this.startFullscreen,
      showClock: showClock ?? this.showClock,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      dlnaEnabled: dlnaEnabled ?? this.dlnaEnabled,
      sourceTimeoutSeconds:
          sourceTimeoutSeconds ?? this.sourceTimeoutSeconds,
      uiScale: uiScale ?? this.uiScale,
      remoteAdminEnabled: remoteAdminEnabled ?? this.remoteAdminEnabled,
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
