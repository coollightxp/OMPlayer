// 条件导出：Web 端空实现，桌面端使用 launch_at_startup
export 'auto_launch_stub.dart' if (dart.library.io) 'auto_launch_io.dart';
