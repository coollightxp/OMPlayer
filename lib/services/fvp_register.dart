// 条件导出：Web 端使用空实现，桌面/移动端使用 fvp 注册
export 'fvp_register_stub.dart' if (dart.library.io) 'fvp_register_io.dart';
