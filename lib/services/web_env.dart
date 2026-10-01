import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 全局 WebView2 环境（仅 Windows 使用）。
/// 通过 additionalBrowserArguments 传入：
///   --disk-cache-size=0          禁用磁盘缓存，不生成 Cache/Code Cache/GPUCache
///   --autoplay-policy=no-user-gesture-required  允许无手势自动播放
WebViewEnvironment? webViewEnvironment;

/// 清理 WebView2 磁盘数据（仅 Windows）。
/// 删除可重建的缓存/状态子目录，保留 Cookies（网站记住用户交互/同意状态，
/// 自动播放需要）。切换频道时调用，避免旧频道的 Service Worker / LocalStorage
/// 等残留导致新频道黑屏、长时间不播放。
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
    // 可安全删除的子目录：缓存 + 站点存储（不含 Cookies）
    final targets = [
      'Cache',
      'Code Cache',
      'GPUCache',
      'Service Worker',
      'Local Storage',
      'Session Storage',
      'IndexedDB',
      'File System',
      'CacheStorage',
    ];
    for (final name in targets) {
      final d = Directory('${wvDir.path}${Platform.pathSeparator}$name');
      if (d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  } catch (_) {}
}

/// 初始化 WebView2 环境（仅 Windows）。
/// 禁用磁盘缓存 + 允许无手势带声自动播放。
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
            '--disk-cache-size=0 --autoplay-policy=no-user-gesture-required',
      ),
    );
  } catch (_) {}
}
