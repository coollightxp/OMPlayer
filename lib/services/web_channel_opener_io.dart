import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:url_launcher/url_launcher.dart';

/// 打开网页频道（TVBox 等源中 webview:// 包装的网站，如央视网）。
/// Windows：用独立 WebView2 窗口打开网站，由网站自身播放器播放，
/// 窗口关闭后返回；缺少 WebView2 运行时或其它平台时回退系统浏览器。
Future<void> openWebChannel(String url, String title) async {
  if (Platform.isWindows) {
    try {
      if (await WebviewWindow.isWebviewAvailable()) {
        final webView = await WebviewWindow.create(
          configuration: CreateConfiguration(
            title: title,
            openMaximized: true,
            titleBarHeight: 44,
          ),
        );
        webView.launch(url);
        // 等待用户关闭网页窗口
        await webView.onClose;
        return;
      }
    } catch (_) {
      // 插件通道异常等：落到系统浏览器兜底
    }
  }
  await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
}
