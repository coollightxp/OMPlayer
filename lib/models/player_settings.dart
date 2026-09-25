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

  const PlayerSettings({
    this.autoPlayNext = true,
    this.defaultVolume = 0.8,
    this.defaultBrightness = 0.8,
    this.pipEnabled = false,
    this.preferredQuality = VideoQuality.auto,
    this.gestureSensitivity = 1.0,
    this.autoHideDelay = 3000,
  });

  PlayerSettings copyWith({
    bool? autoPlayNext,
    double? defaultVolume,
    double? defaultBrightness,
    bool? pipEnabled,
    VideoQuality? preferredQuality,
    double? gestureSensitivity,
    int? autoHideDelay,
  }) {
    return PlayerSettings(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      defaultBrightness: defaultBrightness ?? this.defaultBrightness,
      pipEnabled: pipEnabled ?? this.pipEnabled,
      preferredQuality: preferredQuality ?? this.preferredQuality,
      gestureSensitivity: gestureSensitivity ?? this.gestureSensitivity,
      autoHideDelay: autoHideDelay ?? this.autoHideDelay,
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
