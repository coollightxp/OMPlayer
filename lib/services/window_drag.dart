// 条件导出：Web 使用空实现，桌面端使用 window_manager 实现
export 'window_drag_stub.dart'
    if (dart.library.io) 'window_drag_io.dart';
