import 'dart:io' show Platform;

import 'package:fvp/fvp.dart' as fvp;

/// Windows/Linux 注册 MDK 视频播放后端（video_player 官方不支持桌面端）
void registerFvp() {
  if (Platform.isWindows || Platform.isLinux) {
    fvp.registerWith();
  }
}
