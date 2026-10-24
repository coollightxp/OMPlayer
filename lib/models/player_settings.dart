/// 播放器设置
class PlayerSettings {
  /// 自动播放下一个频道
  final bool autoPlayNext;

  /// 默认音量 (0.0 - 1.0)
  final double defaultVolume;

  /// 默认亮度 (0.0 - 1.0)
  final double defaultBrightness;

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

  /// 网页缓冲秒数（仅展示用，修改后重启生效）
  final int bufferSeconds;

  /// 界面字体缩放（1.0 = 系统默认；4K/8K 大屏可调到 1.5~3.0）
  final double uiScale;

  /// 字体缩放自动适配屏幕分辨率（开启后按屏幕宽度自动计算，忽略 uiScale）
  final bool uiScaleAuto;

  /// 听电视（只放声音）时隐藏窗口（Windows 摸鱼模式）
  final bool listenModeHideWindow;

  /// 听电视时显示信息栏卡片（Android 手机/平板）
  final bool listenModeShowCard;

  const PlayerSettings({
    this.autoPlayNext = true,
    this.defaultVolume = 0.8,
    this.defaultBrightness = 0.8,
    this.gestureSensitivity = 1.0,
    this.autoHideDelay = 3000,
    this.launchAtStartup = false,
    this.startFullscreen = false,
    this.showClock = false,
    this.alwaysOnTop = true,
    this.dlnaEnabled = true,
    this.bufferSeconds = 5,
    this.uiScale = 1.0,
    this.uiScaleAuto = true,
    this.listenModeHideWindow = true,
    this.listenModeShowCard = true,
  });

  PlayerSettings copyWith({
    bool? autoPlayNext,
    double? defaultVolume,
    double? defaultBrightness,
    double? gestureSensitivity,
    int? autoHideDelay,
    bool? launchAtStartup,
    bool? startFullscreen,
    bool? showClock,
    bool? alwaysOnTop,
    bool? dlnaEnabled,
    int? bufferSeconds,
    double? uiScale,
    bool? uiScaleAuto,
    bool? listenModeHideWindow,
    bool? listenModeShowCard,
  }) {
    return PlayerSettings(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      defaultBrightness: defaultBrightness ?? this.defaultBrightness,
      gestureSensitivity: gestureSensitivity ?? this.gestureSensitivity,
      autoHideDelay: autoHideDelay ?? this.autoHideDelay,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startFullscreen: startFullscreen ?? this.startFullscreen,
      showClock: showClock ?? this.showClock,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      dlnaEnabled: dlnaEnabled ?? this.dlnaEnabled,
      bufferSeconds: bufferSeconds ?? this.bufferSeconds,
      uiScale: uiScale ?? this.uiScale,
      uiScaleAuto: uiScaleAuto ?? this.uiScaleAuto,
      listenModeHideWindow: listenModeHideWindow ?? this.listenModeHideWindow,
      listenModeShowCard: listenModeShowCard ?? this.listenModeShowCard,
    );
  }
}
