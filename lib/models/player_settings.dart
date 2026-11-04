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

  /// 播放缓冲秒数：网络抖动时的预读缓冲上限（5/10/20/30 秒，默认 5 秒）。
  /// 由 MDK 后端在启动时应用，修改后重启程序生效
  final int bufferSeconds;

  /// 界面字体缩放（1.0 = 系统默认；4K/8K 大屏可调到 1.5~3.0）
  final double uiScale;

  /// 字体缩放自动适配屏幕分辨率（开启后按屏幕宽度自动计算，忽略 uiScale）
  final bool uiScaleAuto;

  /// 局域网 Web 管理服务开关（手机扫码管理直播源/EPG）
  final bool remoteAdminEnabled;

  /// 网页直播支持开关（默认开）。
  /// 关闭后启动时不清理/不创建 WebView2 运行时环境，网页频道
  /// （webview:// 源）不可用——用于不支持 WebView2 的系统避免退出崩溃
  final bool webEnabled;

  /// 失败自动重载（默认开）：网页频道播放位置连续 24 秒不推进时自动重载；
  /// 内置播放器起播/播放失败时自动重试当前频道。重试次数由
  /// [retryTimes] 决定，次数用尽仍失败则提示链接失效
  final bool autoReloadStall;

  /// 自动重载/重试次数（3/5/10，默认 3）：每个频道连续失败达到该次数后
  /// 判定链接失效，不再自动重试（手动切台或点重试会清零重新计数）
  final int retryTimes;

  /// 投屏点播播完后的处理（秒）：0=立即返回直播；5/30=等待该时长，
  /// 期间发送端连播（电视剧下一集）可继续；超时未等到新投屏才返回直播；
  /// -1=一直等待，直到新投屏到来或手动切台/断开
  final int castEndWaitSeconds;

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
    this.bufferSeconds = 5,
    this.uiScale = 1.0,
    this.uiScaleAuto = true,
    this.remoteAdminEnabled = true,
    this.webEnabled = true,
    this.autoReloadStall = true,
    this.retryTimes = 3,
    this.castEndWaitSeconds = 5,
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
    int? bufferSeconds,
    double? uiScale,
    bool? uiScaleAuto,
    bool? remoteAdminEnabled,
    bool? webEnabled,
    bool? autoReloadStall,
    int? retryTimes,
    int? castEndWaitSeconds,
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
      bufferSeconds: bufferSeconds ?? this.bufferSeconds,
      uiScale: uiScale ?? this.uiScale,
      uiScaleAuto: uiScaleAuto ?? this.uiScaleAuto,
      remoteAdminEnabled: remoteAdminEnabled ?? this.remoteAdminEnabled,
      webEnabled: webEnabled ?? this.webEnabled,
      autoReloadStall: autoReloadStall ?? this.autoReloadStall,
      retryTimes: retryTimes ?? this.retryTimes,
      castEndWaitSeconds: castEndWaitSeconds ?? this.castEndWaitSeconds,
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
