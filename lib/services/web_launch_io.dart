import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// flutter_inappwebview 支持 Windows/Android/macOS/Web；
/// Linux 暂无实现，网页频道回退系统浏览器打开
Future<bool> supportsEmbeddedWeb() async => !Platform.isLinux;

/// 用系统默认浏览器打开网页（Linux 回退路径）
Future<void> launchExternal(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}
