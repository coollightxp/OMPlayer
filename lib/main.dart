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
  if (desktop) {
    await windowManager.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final launchAtStartup =
        prefs.getBool('settings_launch_at_startup') ?? false;
    // 与系统开机启动项保持同步
    await setAutoLaunchEnabled(launchAtStartup);
    // 注意：「启动全屏」不在这里执行——在窗口显示瞬间调用 setFullScreen
    // 会导致窗口尺寸错误（白屏方块+黑边、有声音无画面）。
    // 改由播放器界面首帧布局稳定后延迟执行（applyStartupFullscreen）。

    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'OMPlayer',
        center: true,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        // 窗口置顶（默认开）：避免被其它窗口抢焦点导致快捷键失灵；
        // 设置面板里可关闭
        final alwaysOnTop = prefs.getBool('settings_always_on_top') ?? true;
        if (alwaysOnTop) {
          await windowManager.setAlwaysOnTop(true);
        }
        // 注意：不要在这里切换系统/窗口输入法——
        // Windows 默认未开启“每个应用窗口使用不同输入法”，
        // 任何键盘布局切换都会全局生效。快捷键改用硬件按键事件
        // （KeyDownEvent / WM_KEYDOWN）处理，中文输入法下同样有效，
        // 无需改变用户的输入法状态。
      },
    );
  }

  runApp(const OMPlayerApp());
}
