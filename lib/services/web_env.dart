/// WebView2 环境管理（条件导出）：
/// - 原生平台（Windows 检测/创建 + 缓存清理）走 web_env_io.dart
///   （内部用 dart:ffi 调 WebView2Loader.dll 官方检测接口，
///   dart:ffi 在 Web 上不可用，故必须条件加载）
/// - Web 平台走 web_env_stub.dart 空实现
export 'web_env_stub.dart'
    if (dart.library.io) 'web_env_io.dart';
