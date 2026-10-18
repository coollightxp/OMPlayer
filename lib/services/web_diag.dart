// 条件导出：Web 占位，原生平台内存环形缓冲 + 写文件
export 'web_diag_stub.dart' if (dart.library.io) 'web_diag_io.dart';
