/// 网页频道能力探测与系统浏览器兜底（条件导出）
export 'web_launch_stub.dart' if (dart.library.io) 'web_launch_io.dart';
