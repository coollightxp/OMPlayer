// 条件导出：Web 端空实现，桌面/移动端为本地 HTTP 中转代理
export 'cast_stream_proxy_stub.dart'
    if (dart.library.io) 'cast_stream_proxy_io.dart';
