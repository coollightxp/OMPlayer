import 'dart:ffi';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:ffi/ffi.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

/// 打开网页频道（TVBox 等源中 webview:// 包装的网站，如央视网）。
/// Windows：用独立 WebView2 窗口打开网站，由网站自身播放器播放，
/// 窗口关闭后返回；缺少 WebView2 运行时或其它平台时回退系统浏览器。
Future<void> openWebChannel(String url, String title) async {
  if (Platform.isWindows) {
    bool wasOnTop = false;
    try {
      if (await WebviewWindow.isWebviewAvailable()) {
        // 允许网页直接带声音自动播放（WebView2 默认无手势则静音自动播放）
        _allowAutoplay();
        // 主窗口默认置顶（always-on-top）会把网页窗口压在后面：
        // 先取消置顶，网页窗口提到最前并最大化，网页关闭后再恢复
        try {
          wasOnTop = await windowManager.isAlwaysOnTop();
          if (wasOnTop) await windowManager.setAlwaysOnTop(false);
        } catch (_) {}
        final webView = await WebviewWindow.create(
          configuration: CreateConfiguration(
            title: title,
            openMaximized: true,
            titleBarHeight: 44,
          ),
        );
        webView.launch(url);
        // 提到主窗口前面并最大化，确保用户能看到网页播放器
        await webView.bringToForeground(maximized: true);
        // 等待用户关闭网页窗口
        await webView.onClose;
        return;
      }
    } catch (_) {
      // 插件通道异常等：落到系统浏览器兜底
    } finally {
      if (wasOnTop) {
        try {
          await windowManager.setAlwaysOnTop(true);
        } catch (_) {}
      }
    }
  }
  await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
}

/// WebView2 在无用户手势时默认静音自动播放；通过环境变量追加
/// Chromium 参数放开（加载器创建环境时读取，须在 create 之前设置）
void _allowAutoplay() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setEnv = kernel32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)>(
        'SetEnvironmentVariableW');
    final name = 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'.toNativeUtf16();
    final value = '--autoplay-policy=no-user-gesture-required'.toNativeUtf16();
    setEnv(name, value);
    calloc.free(name);
    calloc.free(value);
  } catch (_) {}
}
