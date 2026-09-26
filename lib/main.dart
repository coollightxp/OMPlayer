import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/auto_launch.dart';
import 'services/fvp_register.dart';
import 'services/media_capture_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows/Linux 注册 MDK 视频播放后端（video_player 官方不支持桌面端）
  registerFvp();

  final desktop = MediaCaptureService.isDesktop;
  bool startFullscreen = false;
  bool launchAtStartup = false;
  if (desktop) {
    await windowManager.ensureInitialized();
    setupAutoLaunch();
    final prefs = await SharedPreferences.getInstance();
    startFullscreen = prefs.getBool('settings_start_fullscreen') ?? false;
    launchAtStartup = prefs.getBool('settings_launch_at_startup') ?? false;
    // 与系统开机启动项保持同步
    await setAutoLaunchEnabled(launchAtStartup);
  }

  runApp(const OMPlayerApp());

  if (desktop && startFullscreen) {
    await windowManager.setFullScreen(true);
  }
}
