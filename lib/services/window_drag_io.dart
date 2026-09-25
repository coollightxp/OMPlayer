import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// 桌面端：按住鼠标左键拖动窗口（Windows/macOS/Linux）
Future<void> startWindowDrag() async {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
  await windowManager.startDragging();
}
