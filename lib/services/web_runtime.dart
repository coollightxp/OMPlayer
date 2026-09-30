/// 内嵌网页运行环境检测（条件导出：IO 平台查注册表，Web 端恒为 true）
export 'web_runtime_stub.dart'
    if (dart.library.io) 'web_runtime_io.dart';
