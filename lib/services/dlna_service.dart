// 条件导出：Web 使用占位实现，原生平台（Windows/Android/Linux/macOS）使用 DLNA 服务
export 'dlna_service_stub.dart' if (dart.library.io) 'dlna_service_io.dart';
