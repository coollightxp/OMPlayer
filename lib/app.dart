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
            // 自动模式按屏幕【物理像素】宽度计算（乘以 devicePixelRatio，
            // 不受系统 DPI 缩放影响）：1080p=1.0，2K≈1.33，4K=2.0，8K=3.0
            double scale;
            if (controller.settings.uiScaleAuto) {
              final physicalW = mq.size.width * mq.devicePixelRatio;
              scale = (physicalW / 1920.0).clamp(1.0, 3.0);
            } else {
              scale = controller.settings.uiScale.clamp(0.8, 3.0);
            }
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
