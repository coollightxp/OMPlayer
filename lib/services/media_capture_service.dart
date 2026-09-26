// 条件导出：Web 端空实现，桌面端负责固定目录与 PNG 编码
export 'media_capture_service_stub.dart'
    if (dart.library.io) 'media_capture_service_io.dart';
