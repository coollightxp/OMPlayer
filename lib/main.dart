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

    // 关键：不能用 WindowOptions(fullScreen: true) 创建窗口——那样
    // window_manager 没有保存正常窗口边界，双击退出全屏时无法正确还原，
    // 表现为不停来回切换/假死。改为在窗口显示前通过 setFullScreen 进入，
    // 与运行期双击全屏走完全相同的代码路径。
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: 'OMPlayer',
        center: true,
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        if (startFullscreen) {
          await windowManager.setFullScreen(true);
        }
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
