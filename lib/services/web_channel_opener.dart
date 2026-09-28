// 条件导出：Web 端不引入直接依赖 dart:io 的 desktop_webview_window
export 'web_channel_opener_stub.dart'
    if (dart.library.io) 'web_channel_opener_io.dart';
