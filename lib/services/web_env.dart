import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 全局 WebView2 环境（仅 Windows 使用）。
/// 通过 additionalBrowserArguments 传入：
///   --disk-cache-size=268435456   磁盘缓存 256MB（加速二次加载）
///   --autoplay-policy=no-user-gesture-required  允许无手势自动播放
WebViewEnvironment? webViewEnvironment;

/// 清理 WebView2 磁盘数据（仅 Windows）。
/// 只删除 Service Worker（旧频道的 Service Worker 可能导致新频道黑屏），
/// 保留 Cache/Cookies/Local Storage/IndexedDB 等，加速二次加载。
void cleanWebView2Cache() {
  if (!Platform.isWindows) return;
  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final exeName = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last
        .replaceAll('.exe', '');
    final wvDir = Directory('${exeDir.path}${Platform.pathSeparator}'
        '${exeName}.WebView2');
    if (!wvDir.existsSync()) return;
    // 只清理 Service Worker，避免旧站点 Service Worker 干扰新频道
    final sw = Directory('${wvDir.path}${Platform.pathSeparator}Service Worker');
    if (sw.existsSync()) {
      try { sw.deleteSync(recursive: true); } catch (_) {}
    }
  } catch (_) {}
}

/// 初始化 WebView2 环境（仅 Windows）。
/// 启用 256MB 磁盘缓存 + 允许无手势带声自动播放。
Future<void> initWebViewEnvironment() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  if (webViewEnvironment != null) return;
  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final exeName = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last
        .replaceAll('.exe', '');
    final userDataFolder =
        '${exeDir.path}${Platform.pathSeparator}${exeName}.WebView2';
    webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: userDataFolder,
        additionalBrowserArguments:
            '--disk-cache-size=268435456 --autoplay-policy=no-user-gesture-required',
      ),
    );
  } catch (_) {}
}
