// 条件导出：Web 使用占位实现，原生平台（Windows/Android/Linux/macOS）使用真实 HTTP 服务
export 'remote_admin_service_stub.dart'
    if (dart.library.io) 'remote_admin_service_io.dart';
