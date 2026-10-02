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
///
/// 启动时清空纯缓存目录：Cache / Code Cache / GPUCache / Service Worker。
/// 实测 WebView2 文件夹臃肿后启动明显变慢，清空后启动快。
/// 保留 Cookies / Local Storage / IndexedDB 等登录态数据。
/// 注意这与「禁用缓存」不同：本次运行期间 HTTP 缓存照常工作，
/// 同一会话内切台/返回仍走缓存，只是不带入上次的旧缓存。
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
    // 纯缓存目录，删除安全
    const cacheDirs = ['Cache', 'Code Cache', 'GPUCache', 'Service Worker'];
    for (final name in cacheDirs) {
      final d =
          Directory('${wvDir.path}${Platform.pathSeparator}$name');
      if (d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
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
