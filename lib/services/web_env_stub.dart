import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Web 平台空实现：无 WebView2 概念，接口与 web_env_io.dart 保持一致。
/// 全局变量保持可读写（player_screen 会访问），函数为空操作。

/// 全局 WebView2 环境（Web 平台恒为 null）。
WebViewEnvironment? webViewEnvironment;

/// 环境创建全部失败时的错误详情（Web 平台恒为空）。
String webEnvLastError = '';

/// 三级检测到的 WebView2 运行时版本（Web 平台恒为 null）。
String? webEnvOfficialVersion;

/// 初始化 WebView2 环境（Web 平台空操作）。
Future<void> initWebViewEnvironment() async {}

/// 清理 WebView2 纯缓存目录（Web 平台空操作）。
void cleanWebView2Cache() {}
