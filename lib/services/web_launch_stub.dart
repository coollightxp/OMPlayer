/// Web 端：flutter_inappwebview 提供 iframe 内嵌实现
Future<bool> supportsEmbeddedWeb() async => true;

/// Web 端无需系统浏览器兜底
Future<void> launchExternal(String url) async {}
