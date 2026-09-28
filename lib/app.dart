import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/player_controller.dart';
import 'screens/player_screen.dart';

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
          theme: ThemeData.dark(useMaterial3: true).copyWith(
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
