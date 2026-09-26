// 条件导出：Web 端空实现，桌面/移动端走 fvp(MDK) 原生能力
export 'native_capture_stub.dart'
    if (dart.library.io) 'native_capture_io.dart';
