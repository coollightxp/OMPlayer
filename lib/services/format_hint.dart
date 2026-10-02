// 条件导出：Web 端使用空实现，桌面/移动端使用 dart:io 预检
export 'format_hint_stub.dart'
    if (dart.library.io) 'format_hint_io.dart';
