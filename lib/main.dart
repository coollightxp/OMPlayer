import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/auto_launch.dart';
import 'services/fvp_register.dart';
import 'services/keyboard_layout.dart';
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
  if (desktop) {
    await windowManager.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final launchAtStartup =
        prefs.getBool('settings_launch_at_startup') ?? false;
    // 与系统开机启动项保持同步
    await setAutoLaunchEnabled(launchAtStartup);

    // 标题栏默认隐藏；鼠标移到顶部出现悬停标题栏（TopTitleBar），
    // 提供最小化/最大化/关闭
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'OMPlayer',
        center: true,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        // 启动后把输入法切到英文，避免快捷键被中文输入法拦截
        forceEnglishKeyboard();
      },
    );
  }

  runApp(const OMPlayerApp());
}
