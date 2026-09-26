import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // 安卓手机：强制横屏（直播/电视场景，竖屏会留黑边）
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  final desktop = MediaCaptureService.isDesktop;
  bool startFullscreen = false;
  bool launchAtStartup = false;
  if (desktop) {
    await windowManager.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    startFullscreen = prefs.getBool('settings_start_fullscreen') ?? false;
    launchAtStartup = prefs.getBool('settings_launch_at_startup') ?? false;
    // 与系统开机启动项保持同步
    await setAutoLaunchEnabled(launchAtStartup);

    // 关键：必须在窗口首次显示前设置全屏，否则窗口样式切换会导致
    // 窗口掉到最底层、点击无响应等异常
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        fullScreen: startFullscreen,
        title: 'OMPlayer',
        center: true,
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        // 启动即全屏时保持窗口置顶，避免被其它窗口覆盖
        if (startFullscreen) {
          await windowManager.setAlwaysOnTop(true);
        }
      },
    );
  }

  runApp(const OMPlayerApp());
}
