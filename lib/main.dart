import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/media_capture_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端初始化窗口管理器（用于双击全屏）
  if (MediaCaptureService.isDesktop) {
    await windowManager.ensureInitialized();
  }
  runApp(const OMPlayerApp());
}
