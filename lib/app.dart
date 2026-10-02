import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/player_controller.dart';
import 'screens/player_screen.dart';

/// 各平台选用观感更清晰、圆润的系统无衬线字体：
/// Windows 用「Microsoft YaHei UI」（比默认回退的雅黑小字号更清晰），
/// Linux 用 Noto Sans CJK SC；macOS/iOS/Android 沿用系统默认
/// （SF Pro / 苹方 / Roboto，本身已经足够圆润）
String? get _platformFontFamily {
  if (kIsWeb) return null;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'Microsoft YaHei UI';
    case TargetPlatform.linux:
      return 'Noto Sans CJK SC';
    default:
      return null;
  }
}

class OMPlayerApp extends StatelessWidget {
  const OMPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerController(),
      child: Consumer<PlayerController>(
        // 字体缩放变化时重建整个应用，让 4K/8K 等大屏可整体放大文字
        builder: (context, controller, _) => MaterialApp(
          title: 'OMPlayer',
          debugShowCheckedModeBanner: false,
          // 全局统一字体族须在 ThemeData 构造函数传入（copyWith 无此参数）
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: _platformFontFamily,
          ).copyWith(
            scaffoldBackgroundColor: Colors.black,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blueAccent,
              brightness: Brightness.dark,
            ),
          ),
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            // 两级缩放相乘：
            //  formFactor（设备形态，用最短边判断——手机横屏宽是长边）：
            //    安卓手机<600 → 0.72；小平板<720 → 0.9；其余 → 1.0
            //  userFactor（用户在设置里的「界面缩放」）：
            //    自动 → TV 按物理宽度放大；手动 → 用户选定值
            final shortest = mq.size.shortestSide;
            final isAndroid = !kIsWeb &&
                defaultTargetPlatform == TargetPlatform.android;
            double formFactor;
            if (isAndroid && shortest < 600) {
              formFactor = 0.72;
            } else if (isAndroid && shortest < 720) {
              formFactor = 0.9;
            } else {
              formFactor = 1.0;
            }
            double userFactor;
            if (controller.settings.uiScaleAuto) {
              if (formFactor < 1.0) {
                // 手机/小平板：自动模式不做 TV 物理宽度放大
                userFactor = 1.0;
              } else {
                // 按屏幕【物理像素】宽度（乘 devicePixelRatio，不受系统 DPI 影响）：
                // 1080p=1.0，2K≈1.33，4K=2.0，8K=3.0
                final physicalW = mq.size.width * mq.devicePixelRatio;
                userFactor = (physicalW / 1920.0).clamp(1.0, 3.0);
              }
            } else {
              userFactor =
                  controller.settings.uiScale.clamp(0.8, 3.0);
            }
            final scale = formFactor * userFactor;
            return MediaQuery(
              data: mq.copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
          },
          home: const PlayerScreen(),
        ),
      ),
    );
  }
}
