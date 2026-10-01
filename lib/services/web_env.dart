import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 全局 WebView2 环境（仅 Windows 使用）。
/// 通过 additionalBrowserArguments 传入：
///   --disk-cache-size=0          禁用磁盘缓存，不生成 Cache/Code Cache/GPUCache
///   --autoplay-policy=no-user-gesture-required  允许无手势自动播放
WebViewEnvironment? webViewEnvironment;
