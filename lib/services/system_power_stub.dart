/// Web 端无法使用 dart:io，关机为空操作（Web 不渲染关机按钮，
/// 正常不会被调用）
Future<void> shutdownSystem() async {}
