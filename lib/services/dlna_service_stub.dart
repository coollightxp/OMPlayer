/// Web 端占位实现（DLNA 仅原生平台可用）
class DlnaHooks {
  final void Function(String url, String title) onPlay;
  final void Function() onPause;
  final void Function() onResume;
  final void Function() onStop;
  final void Function(Duration position) onSeek;
  final void Function(double volume) onSetVolume;
  final void Function(bool muted) onSetMute;
  final String Function() transportState;
  final Duration Function() position;
  final Duration Function() duration;
  final double Function() volume;
  final bool Function() muted;

  const DlnaHooks({
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onSeek,
    required this.onSetVolume,
    required this.onSetMute,
    required this.transportState,
    required this.position,
    required this.duration,
    required this.volume,
    required this.muted,
  });
}

class DlnaService {
  bool get isRunning => false;

  String get deviceName => '';

  String get deviceEndpoint => '';

  Future<void> start({required String uuid, required DlnaHooks hooks}) async {}

  void stop() {}

  void clearCurrentMedia() {}
}
