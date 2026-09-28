// 条件导出：Web 使用占位实现，桌面端使用 Win32 FFI
export 'numlock_service_stub.dart'
    if (dart.library.io) 'numlock_service_io.dart';
