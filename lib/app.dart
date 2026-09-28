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
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(controller.settings.uiScale),
              ),
              child: child!,
            );
          },
          home: const PlayerScreen(),
        ),
      ),
    );
  }
}
