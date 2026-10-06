// 条件导出：Web 端空实现，Windows/Linux 使用 dart:io 调用系统关机
export 'system_power_stub.dart'
    if (dart.library.io) 'system_power_io.dart';
